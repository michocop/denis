import SwiftUI
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Owns the session and decides what the app shows.
///
/// The decision comes from `my_account_state()` rather than from anything the
/// client works out for itself: whether an account is ready, awaiting approval
/// or suspended is the server's answer, and a client that decided locally
/// would be one patched build away from letting a suspended member back in.
@Observable
public final class AppModel {

    public enum Phase {
        case launching
        case signedOut(String?)
        /// Signed in for the first time: the account exists (an invitation
        /// opened it) and has no name yet.
        case completingInvite(email: String)
        case pendingApproval(email: String)
        case suspended
        case locked
        case ready(Dependencies, UserRole, String, isDemo: Bool)
    }

    public private(set) var phase: Phase = .launching

    private var client: SupabaseClient?
    private let sessionStore: SessionStore
    private var email: String = ""
    /// A link that opened the app before the client existed (a cold launch).
    private var pendingCallback: URL?

    public init(sessionStore: SessionStore = SessionStore()) {
        self.sessionStore = sessionStore
    }

    private struct AccountState: Decodable {
        let state: String
        let role: UserRole?
        let fullName: String?
    }

    // MARK: - Launch

    /// Launching with -demo (optionally -admin) wires every screen to the
    /// sample repositories and skips sign-in entirely. It exists so the app can
    /// be looked at on a simulator before a Supabase project exists, and so the
    /// screenshot job has something deterministic to photograph.
    @MainActor
    public func startDemo(asAdmin: Bool) {
        phase = .ready(
            Dependencies(
                recommendations: PreviewRecommendationsRepository(),
                chat: PreviewChatRepository(viewer: asAdmin ? DemoChatStore.them : DemoChatStore.me),
                profiles: PreviewProfileRepository(role: asAdmin ? .admin : .apporteur),
                invoices: PreviewInvoiceRepository(),
                reminders: PreviewRemindersRepository(),
                admin: PreviewAdminRepository(),
                commissions: PreviewCommissionsRepository(),
                notifications: PreviewNotificationsRepository(),
                legal: PreviewLegalRepository(),
                sms: PreviewSmsRepository(required: true),
                contracts: PreviewContractRepository()
            ),
            asAdmin ? .admin : .apporteur,
            asAdmin ? "Pierre-Louis Tettamanti" : "Johann Lefeuvre",
            isDemo: true
        )
    }

    @MainActor
    public func start() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-demo") {
            startDemo(asAdmin: arguments.contains("-admin"))
            return
        }

        // No backend configured means there is nothing to sign in to, so a
        // sign-in form would be a dead end. Fall back to the sample data
        // rather than to a screen that cannot work.
        guard let config = try? AppConfig.supabase() else {
            startDemo(asAdmin: arguments.contains("-admin"))
            return
        }

        let client = SupabaseClient(baseURL: config.url, anonKey: config.key)
        self.client = client
        // Every rotation goes to the Keychain, including the ones that happen
        // mid-session when an access token expires. Only the launch, sign-in
        // and sign-up saved it before, so an hour into using the app the
        // Keychain held a spent token and the next launch meant signing in
        // again.
        let store = sessionStore
        await client.setRefreshTokenObserver { token in _ = try? store.save(refreshToken: token) }

        // Opened by an emailed link: that link is the session, whatever was
        // stored before.
        if let url = pendingCallback {
            pendingCallback = nil
            await handle(url: url)
            return
        }

        guard let refreshToken = sessionStore.refreshToken() else {
            phase = .signedOut(nil)
            return
        }

        do {
            let session = try await client.restore(refreshToken: refreshToken)
            try sessionStore.save(refreshToken: session.refreshToken)
            await client.setRefreshToken(session.refreshToken)
            email = session.user.email ?? ""
            // A restored session was earned earlier, not now: make the person
            // prove the device is theirs before it is reused.
            phase = BiometricGate.isAvailable ? .locked : await resolvePhase()
        } catch {
            // A refresh token that no longer works is not an error worth
            // showing; it just means signing in again.
            sessionStore.clear()
            phase = .signedOut(nil)
        }
    }

    /// Successful Face ID unlocks, counted so the root view can answer each
    /// with a vibration.
    public private(set) var unlocks = 0

    @MainActor
    public func unlock() async {
        guard await BiometricGate.authenticate() else { return }
        unlocks += 1
        phase = await resolvePhase()
    }

    // MARK: - Credentials

    @MainActor
    public func signIn(email: String, password: String) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        let session = try await client.signIn(email: email, password: password)
        try? sessionStore.save(refreshToken: session.refreshToken)
        await client.setRefreshToken(session.refreshToken)
        self.email = session.user.email ?? email
        phase = await resolvePhase()
    }

    /// Sign-in is by emailed code: nobody has a password to forget, and an
    /// invitation is no longer a link that has to survive the mail provider's
    /// click tracking -- the address is the invitation.
    @MainActor
    public func sendEmailCode(to email: String) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        try await client.sendEmailCode(to: Self.normalized(email))
    }

    @MainActor
    public func verifyEmailCode(_ code: String, email: String) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        let session = try await client.verifyEmailCode(code, email: Self.normalized(email))
        try? sessionStore.save(refreshToken: session.refreshToken)
        await client.setRefreshToken(session.refreshToken)
        self.email = session.user.email ?? email
        phase = await resolvePhase()
    }

    static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Turns a signed-in account with no profile into a member: the
    /// invitation addressed to it gives the role.
    @MainActor
    public func redeem(code: String, firstName: String, lastName: String) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        // The auth account exists but owns nothing until the invitation is
        // redeemed, which is what assigns the role.
        let _: Profile = try await client.rpc("redeem_invite", body: [
            "p_code": AnyEncodable(code.uppercased().trimmingCharacters(in: .whitespaces)),
            "p_first_name": AnyEncodable(firstName),
            "p_last_name": AnyEncodable(lastName)
        ])
        phase = await resolvePhase()
    }

    // MARK: - Emailed links

    /// A password reset, an address confirmation or an invitation coming back
    /// from the email. The link carries a session; it is taken over, saved,
    /// and the app goes where the link was for.
    @MainActor
    public func handle(url: URL) async {
        guard let parsed = AuthCallback.parse(url) else { return }
        guard let client else {
            pendingCallback = url
            return
        }
        switch parsed {
        case .failure(let failure):
            phase = .signedOut(failure.localizedDescription)
        case .success(let callback):
            do {
                await client.setAccessToken(callback.accessToken)
                let session = try await client.restore(refreshToken: callback.refreshToken)
                try? sessionStore.save(refreshToken: session.refreshToken)
                email = session.user.email ?? ""
                // an invitation or reset link sent before sign-in by code: it
                // signs in, and routing asks for a name if one is missing
                phase = await resolvePhase()
            } catch {
                phase = .signedOut(AuthCallback.Failure.expired.localizedDescription)
            }
        }
    }

    /// The invited person names themselves; the invitation addressed to
    /// their email does the rest -- no code to type, no password to choose.
    @MainActor
    public func completeInvite(firstName: String, lastName: String) async throws {
        try await redeem(code: "", firstName: firstName, lastName: lastName)
    }

    @MainActor
    public func backToSignIn() {
        phase = .signedOut(nil)
    }

    @MainActor
    public func refreshAccountState() async {
        phase = await resolvePhase()
    }

    @MainActor
    public func signOut() async {
        // Before the token is discarded, while the request can still be
        // authenticated: a push token left attached to whoever registered it
        // puts their commissions on the next person's lock screen.
        if let client {
            try? await SupabaseNotificationsRepository(client: client).forgetDevices()
        }
        await LocalNotifications.setBadge(0)
        PushCenter.shared.detach()
        DiagnosticsReporter.shared.stop()
        await client?.signOut()
        sessionStore.clear()
        phase = .signedOut(nil)
    }

    // MARK: - Routing

    @MainActor
    private func resolvePhase() async -> Phase {
        guard let client else { return .signedOut(nil) }
        do {
            let account: AccountState = try await client.rpc("my_account_state")
            switch account.state {
            case "ready":
                DiagnosticsReporter.shared.start(client: client)
                let profiles = SupabaseProfileRepository(client: client)
                return .ready(
                    Dependencies(
                        recommendations: SupabaseRecommendationsRepository(client: client),
                        chat: SupabaseChatRepository(client: client),
                        profiles: profiles,
                        invoices: SupabaseInvoiceRepository(client: client),
                        reminders: SupabaseRemindersRepository(client: client),
                        admin: SupabaseAdminRepository(client: client),
                        commissions: SupabaseCommissionsRepository(client: client),
                        notifications: SupabaseNotificationsRepository(client: client),
                        legal: SupabaseLegalRepository(client: client),
                        changeMonitor: PollingChangeMonitor(client: client),
                        documents: SupabaseDocumentsRepository(client: client),
                        sms: SupabaseSmsRepository(client: client),
                        contracts: SupabaseContractRepository(client: client)
                    ),
                    account.role ?? .apporteur,
                    account.fullName ?? "",
                    isDemo: false
                )
            case "pending_approval": return .pendingApproval(email: email)
            // signed in, not yet introduced: an account only exists because
            // this address was invited, and the invitation is found by it
            case "needs_invite":     return .completingInvite(email: email)
            case "suspended":        return .suspended
            default:                 return .signedOut(nil)
            }
        } catch {
            return .signedOut(error.localizedDescription)
        }
    }
}

public extension AppModel.Phase {
    var isLaunching: Bool {
        if case .launching = self { return true }
        return false
    }
}

public struct AppRootView: View {
    @State private var model = AppModel()
    /// The opening covers everything until it has played and the session is
    /// known. A cold launch only: coming back from the background keeps this
    /// view, so it does not play again.
    @State private var showsIntro = true

    public init() {
        Theme.registerFonts()
        Self.styleSystemBars()
    }

    /// Navigation titles are drawn by UIKit, not by Theme, so they are told
    /// about the brand faces here: Sora, like every other title in the app.
    private static func styleSystemBars() {
        #if canImport(UIKit)
        let ink = UIColor(Theme.Palette.textPrimary)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        if let inline = UIFont(name: "Sora", size: 17) {
            appearance.titleTextAttributes = [
                .font: UIFontMetrics(forTextStyle: .headline).scaledFont(
                    for: inline.withWeight(.semibold)),
                .foregroundColor: ink]
        }
        if let large = UIFont(name: "Sora", size: 32) {
            appearance.largeTitleTextAttributes = [
                .font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(
                    for: large.withWeight(.semibold)),
                .foregroundColor: ink]
        }
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        #endif
    }

    public var body: some View {
        ZStack {
            screens
                .environment(\.contentRevealed, !showsIntro)

            if showsIntro {
                LaunchIntroView(isSessionKnown: !model.phase.isLaunching) {
                    withAnimation(.easeOut(duration: 0.35)) { showsIntro = false }
                }
                // leaves by growing slightly as it fades: through the mark
                .transition(.opacity.combined(with: .scale(scale: 1.08)))
                .zIndex(1)
            }
        }
        // Dark, like trinity-energie.fr: the brand is night navy and one blue.
        .preferredColorScheme(.dark)
        .onOpenURL { url in Task { await model.handle(url: url) } }
        .tint(Theme.Palette.brand)
        .feedback(.success, trigger: model.unlocks)
        .task { await model.start() }
    }

    @ViewBuilder
    private var screens: some View {
        Group {
            switch model.phase {
            case .launching:
                // under the opening, which stays until this phase is over
                BrandBackground()

            case .signedOut(let message):
                signedOut(message)

            case .locked:
                LockedView { await model.unlock() }

            case .completingInvite(let email):
                CompleteInviteView(email: email,
                                   onSignOut: { Task { await model.signOut() } }) { first, last in
                    try await model.completeInvite(firstName: first, lastName: last)
                }

            case .pendingApproval(let email):
                PendingApprovalView(
                    email: email,
                    onRefresh: { await model.refreshAccountState() },
                    onSignOut: { Task { await model.signOut() } }
                )

            case .suspended:
                SuspendedView { Task { await model.signOut() } }

            case .ready(let dependencies, let role, let name, let isDemo):
                RootView(dependencies: dependencies, role: role, signerName: name,
                         isDemo: isDemo) {
                    Task { await model.signOut() }
                }
            }
        }
    }

    private func signedOut(_ message: String?) -> some View {
        SignInView(
            notice: message,
            sendCode: { email in try await model.sendEmailCode(to: email) },
            verifyCode: { code, email in try await model.verifyEmailCode(code, email: email) },
            onDemo: { asAdmin in model.startDemo(asAdmin: asAdmin) }
        )
    }
}
