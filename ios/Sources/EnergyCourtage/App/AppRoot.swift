import SwiftUI
import Observation

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
        case needsInvite(email: String)
        case pendingApproval(email: String)
        case suspended
        case locked
        case ready(Dependencies, UserRole, String, isDemo: Bool)
    }

    public private(set) var phase: Phase = .launching

    private var client: SupabaseClient?
    private let sessionStore: SessionStore
    private var email: String = ""

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
                commissions: PreviewCommissionsRepository()
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

    @MainActor
    public func unlock() async {
        guard await BiometricGate.authenticate() else { return }
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

    @MainActor
    public func register(code: String, firstName: String, lastName: String,
                         email: String, password: String) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        let session = try await client.signUp(email: email, password: password)
        try? sessionStore.save(refreshToken: session.refreshToken)
        await client.setRefreshToken(session.refreshToken)
        self.email = session.user.email ?? email

        // The auth account exists but owns nothing until the invitation is
        // redeemed, which is what assigns the role.
        let _: Profile = try await client.rpc("redeem_invite", body: [
            "p_code": AnyEncodable(code.uppercased().trimmingCharacters(in: .whitespaces)),
            "p_first_name": AnyEncodable(firstName),
            "p_last_name": AnyEncodable(lastName)
        ])
        phase = await resolvePhase()
    }

    @MainActor
    public func requestPasswordReset(email: String) async {
        await client?.requestPasswordReset(email: email)
    }

    @MainActor
    public func refreshAccountState() async {
        phase = await resolvePhase()
    }

    @MainActor
    public func signOut() async {
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
                        changeMonitor: PollingChangeMonitor(client: client)
                    ),
                    account.role ?? .apporteur,
                    account.fullName ?? "",
                    isDemo: false
                )
            case "pending_approval": return .pendingApproval(email: email)
            case "needs_invite":     return .needsInvite(email: email)
            case "suspended":        return .suspended
            default:                 return .signedOut(nil)
            }
        } catch {
            return .signedOut(error.localizedDescription)
        }
    }
}

public struct AppRootView: View {
    @State private var model = AppModel()
    @State private var showsSignUp = false
    @State private var showsForgotPassword = false

    public init() {}

    public var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Palette.canvas)

            case .signedOut(let message):
                signedOut(message)

            case .locked:
                LockedView { await model.unlock() }

            // Registered, but the invitation was never redeemed — most likely
            // the app was closed mid-sign-up.
            case .needsInvite:
                SignUpView { code, first, last, email, password in
                    try await model.register(code: code, firstName: first, lastName: last,
                                             email: email, password: password)
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
        .task { await model.start() }
    }

    private func signedOut(_ message: String?) -> some View {
        VStack(spacing: Theme.Spacing.m) {
            SignInView(
                signIn: { email, password in
                    try await model.signIn(email: email, password: password)
                },
                onCreateAccount: { showsSignUp = true },
                onForgotPassword: { showsForgotPassword = true }
            )
            if let message {
                Text(message)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.destructive)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.gutter)
            }
        }
        .sheet(isPresented: $showsSignUp) {
            SignUpView { code, first, last, email, password in
                try await model.register(code: code, firstName: first, lastName: last,
                                         email: email, password: password)
            }
        }
        .sheet(isPresented: $showsForgotPassword) {
            ForgotPasswordView { email in await model.requestPasswordReset(email: email) }
        }
    }
}
