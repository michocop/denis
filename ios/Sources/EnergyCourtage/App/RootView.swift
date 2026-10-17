import SwiftUI

/// The four-tab shell. One binary serves both populations: the tabs are the
/// same, and `role` decides which affordances appear inside them.
public struct RootView: View {
    public enum Tab: Hashable { case home, recommendations, chat, profile }

    @State private var tab: Tab = .home
    @State private var showsCreate = false
    @State private var showsNotifications = false
    @State private var showsMandate = false
    /// Bumped when something outside Home changes what it shows.
    @State private var homeRefresh = 0
    @State private var notifications: NotificationsViewModel
    @State private var connectivity = Connectivity()
    @State private var legal: LegalViewModel
    @State private var requiredDocument: LegalDocumentKey?
    /// An apporteur who has not signed the contract yet starts there.
    @State private var showsOnboarding = false
    /// An invoice opened from a notification, over whatever tab is showing.
    @State private var openedInvoice: OpenedInvoice?
    /// Recommendations sent from the create sheet, counted for the vibration:
    /// the sheet is gone by the time it would play there.
    @State private var created = 0
    /// Tabs changed by a tap, as opposed to by a notification or a sent
    /// recommendation, which have their own vibration or none.
    @State private var tabTaps = 0
    private var push = PushCenter.shared

    private struct OpenedInvoice: Identifiable {
        let id: UUID
    }

    /// False while the opening still covers the screen.
    @Environment(\.contentRevealed) private var revealed

    private let dependencies: Dependencies
    private let role: UserRole
    private let signerName: String
    private let isDemo: Bool
    private let onSignOut: () -> Void

    public init(dependencies: Dependencies, role: UserRole, signerName: String,
                isDemo: Bool = false,
                onSignOut: @escaping () -> Void) {
        self.dependencies = dependencies
        self.role = role
        self.signerName = signerName
        self.isDemo = isDemo
        self.onSignOut = onSignOut
        _notifications = State(wrappedValue:
            NotificationsViewModel(repository: dependencies.notifications))
        _legal = State(wrappedValue: LegalViewModel(repository: dependencies.legal))
    }

    /// The documents everyone has to have accepted to use the app. The mandate
    /// is not one of them: only an apporteur signs it, from the profile, and
    /// the database already refuses to invoice anyone without it.
    private static let requiredDocuments: Set<String> = ["cgu", "confidentialite"]

    /// Presents the next published version this person has not accepted --
    /// a first launch, or a revised CGU. `LegalViewModel.outstanding` existed
    /// and nothing ever looked at it, so nobody was ever asked.
    @MainActor
    private func presentOutstandingDocuments() async {
        guard !isDemo else { return await presentOnboardingIfNeeded() }
        await legal.load()
        // Offline, the last list is all there is; presenting from it would
        // reopen the sheet every time it was closed.
        guard legal.errorMessage == nil else { return }
        requiredDocument = legal.outstanding
            .first { Self.requiredDocuments.contains($0.key) }
            .map { LegalDocumentKey(id: $0.key) }
        if requiredDocument == nil { await presentOnboardingIfNeeded() }
    }

    /// After the CGU and the privacy policy, and only for an apporteur: the
    /// company's side has no contract to sign.
    @MainActor
    private func presentOnboardingIfNeeded() async {
        guard !role.isAdmin,
              let profile = try? await dependencies.profiles.currentProfile() else { return }
        showsOnboarding = !profile.hasSignedContract
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Said plainly, because a request that fails with no signal used
            // to come back as "Une erreur est survenue" — which reads as "the
            // app is broken" to someone standing in a client's basement.
            if !connectivity.isOnline {
                // Nothing is queued while offline, so this must not promise
                // that changes will be sent later: they will not.
                Label("Hors ligne — vos modifications ne peuvent pas être enregistrées",
                      systemImage: "wifi.slash")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Theme.Palette.textSecondary)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // No banner in demo: it is entered only through "Découvrir
            // l'application (démo)", whose confirmation says the data is
            // fictitious, and a strip on every screen made the app look
            // unfinished.
            tabs
                .fullScreenCover(isPresented: $showsOnboarding) {
                    OnboardingView(
                        model: OnboardingModel(profiles: dependencies.profiles, legal: dependencies.legal,
                                               sms: dependencies.sms, contracts: dependencies.contracts),
                        onFinished: {
                            showsOnboarding = false
                            homeRefresh += 1      // the mandate notice goes with the signature
                        },
                        onSignOut: onSignOut)
                    .interactiveDismissDisabled()
                }
        }
        .animation(.snappy, value: connectivity.isOnline)
        .sheet(isPresented: $showsMandate) {
            LegalDocumentView(model: LegalViewModel(repository: dependencies.legal),
                              documentKey: "mandat_facturation")
                .onDisappear { homeRefresh += 1 }   // the notice goes once it is signed
        }
        .sheet(isPresented: $showsNotifications) {
            NotificationsView(model: notifications)
                .onDisappear { Task { await notifications.refreshBadge() } }
        }
        .fullScreenCover(item: $requiredDocument,
                         onDismiss: { Task { await presentOutstandingDocuments() } }) { key in
            LegalDocumentView(model: LegalViewModel(repository: dependencies.legal),
                              documentKey: key.id, isRequired: true)
        }
        .task { await presentOutstandingDocuments() }
        .task(id: revealed) {
            // Asked for here rather than at launch: a permission prompt on the
            // first screen, before the app has done anything, is the one
            // people decline. And not over the opening, which it would
            // otherwise interrupt mid-pulse.
            guard revealed else { return }
            await LocalNotifications.requestPermission()
            guard !isDemo else { return }
            await push.attach(dependencies.notifications)
            PushRegistration.registerIfAvailable()
        }
        // A tapped notification -- on the lock screen or in the list -- opens
        // what it is about instead of whatever tab was last showing.
        .onChange(of: push.route, initial: true) { _, route in
            guard let route else { return }
            switch route {
            case .invoice(let id):
                push.route = nil
                showsNotifications = false
                openedInvoice = OpenedInvoice(id: id)
            case .thread:
                showsNotifications = false
                tab = .chat           // ChatView opens the thread and clears the route
            case .recommendation:
                showsNotifications = false
                tab = .recommendations
            }
        }
        .sheet(item: $openedInvoice) { opened in
            NavigationStack {
                InvoiceView(model: InvoiceViewModel(invoiceID: opened.id,
                                                    repository: dependencies.invoices,
                                                    sms: dependencies.sms),
                            signerName: signerName, isAdmin: role.isAdmin)
            }
        }
        .task(id: connectivity.reconnections) {
            // Re-read on every reconnection as well as at launch, so coming
            // out of a tunnel does not leave a stale badge until the next poll.
            await notifications.refreshBadge()
            await LocalNotifications.setBadge(notifications.unread)
        }
        .task {
            for await _ in dependencies.changeMonitor.changes() {
                await notifications.refreshBadge()
                await LocalNotifications.setBadge(notifications.unread)
            }
        }
    }

    /// The bell, with its unread count. Placed in the navigation bar of each
    /// tab rather than as a fifth tab: the four tabs are what the original
    /// has, and notifications are a thing you check, not a place you go.
    @ToolbarContentBuilder
    private var notificationsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showsNotifications = true } label: {
                Image(systemName: notifications.unread > 0 ? "bell.badge" : "bell")
                    .foregroundStyle(Theme.Palette.brand)
            }
            .accessibilityLabel(notifications.unread > 0
                                ? "Notifications, \(notifications.unread) non lues"
                                : "Notifications")
        }
    }

    /// The bell as a glass button, for a header that is not a navigation bar.
    private var bell: some View {
        Button { showsNotifications = true } label: {
            Image(systemName: notifications.unread > 0 ? "bell.badge.fill" : "bell")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.Palette.brand)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.bounce, value: notifications.unread)
                .frame(width: 44, height: 44)
                .brandGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(notifications.unread > 0
                            ? "Notifications, \(notifications.unread) non lues"
                            : "Notifications")
    }

    private var tabs: some View {
        TabView(selection: Binding(get: { tab }, set: { new in
            if new != tab { tabTaps += 1 }
            tab = new
        })) {
            NavigationStack {
                // the bell sits in the header row, beside the wordmark
                HomeView(model: HomeViewModel(profiles: dependencies.profiles),
                         accessory: AnyView(bell),
                         onOpenMandate: { showsMandate = true },
                         refreshToken: homeRefresh) {
                    showsCreate = true
                }
                .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem { Label("Accueil", systemImage: "house") }
            .tag(Tab.home)
            .badge(notifications.unread)

            RecommendationsView(
                model: RecommendationsViewModel(repository: dependencies.recommendations,
                                                role: role,
                                                changeMonitor: dependencies.changeMonitor),
                dependencies: dependencies,
                signerName: signerName
            )
            .tabItem { Label("Reco", systemImage: "doc.badge.plus") }
            .tag(Tab.recommendations)

            ChatView(model: ChatViewModel(repository: dependencies.chat,
                                          profiles: dependencies.profiles,
                                          admin: role.isAdmin ? dependencies.admin : nil))
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chat)

            ProfileView(model: ProfileViewModel(repository: dependencies.profiles),
                        dependencies: dependencies,
                        onSignOut: onSignOut)
                .tabItem { Label("Profil", systemImage: "person.circle") }
                .tag(Tab.profile)
        }
        .tint(Theme.Palette.brand)
        .feedback(.selection, trigger: tabTaps)
        .feedback(.success, trigger: created)
        .sheet(isPresented: $showsCreate) {
            CreateRecommendationView(recommendations: dependencies.recommendations,
                                     documents: dependencies.documents) { _ in
                tab = .recommendations
                created += 1
            }
        }
    }
}

/// Sign-in by emailed code: the address, then the six digits sent to it.
/// One screen that fits the phone -- nothing to scroll -- and no password:
/// signup is invitation-based, so an address only has an account because
/// Trinity Énergie invited it.
public struct SignInView: View {
    private enum Step: Equatable { case email, code(String) }

    @State private var step: Step = .email
    @State private var email = ""
    @State private var code = ""
    @State private var codePhase: SmsCodeField.Phase = .entering
    @State private var shakes = 0
    @State private var errorMessage: String?
    @State private var resent = false
    @State private var isSending = false
    @State private var resendAvailableAt = Date.distantPast
    @State private var now = Date.now
    @State private var choosesDemo = false
    @FocusState private var emailFocused: Bool

    private let sendCode: (String) async throws -> Void
    private let verifyCode: (String, String) async throws -> Void
    /// Opens the app on sample data, as an apporteur (false) or as the company.
    private let onDemo: ((Bool) -> Void)?

    public init(notice: String? = nil,
                sendCode: @escaping (_ email: String) async throws -> Void,
                verifyCode: @escaping (_ code: String, _ email: String) async throws -> Void,
                onDemo: ((Bool) -> Void)? = nil) {
        self.sendCode = sendCode
        self.verifyCode = verifyCode
        self.onDemo = onDemo
        _errorMessage = State(initialValue: notice)
    }

    private var isValidEmail: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        guard let at = trimmed.firstIndex(of: "@") else { return false }
        return trimmed[trimmed.index(after: at)...].contains(".") && !trimmed.contains(" ")
    }
    private var secondsBeforeResend: Int {
        max(0, Int(resendAvailableAt.timeIntervalSince(now).rounded(.up)))
    }
    /// With the keyboard up the screen keeps only what is being typed into.
    private var isTyping: Bool { emailFocused || step != .email }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrinityWordmark()
                .padding(.top, Theme.Spacing.l)
                .staggeredAppear(index: 0)

            Spacer(minLength: Theme.Spacing.l)

            // the site's headline: white, then the blue gradient
            VStack(alignment: .leading, spacing: 2) {
                Text("Votre espace")
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("apporteur d'affaires.")
                    .brandGradient()
            }
            .font(Theme.Typography.display(34, .semibold, relativeTo: .largeTitle))
            .minimumScaleFactor(0.8)
            .staggeredAppear(index: 1)

            if !isTyping {
                Text("Suivez vos recommandations, signez vos factures et recevez vos commissions.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Spacing.m)
                    .transition(.opacity)
                    .staggeredAppear(index: 2)
            }

            Spacer(minLength: Theme.Spacing.l)

            card
                .staggeredAppear(index: 3)

            Spacer(minLength: Theme.Spacing.m)

            if !isTyping { footer.transition(.opacity) }
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.bottom, Theme.Spacing.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BrandBackground())
        .animation(.smooth(duration: 0.3), value: isTyping)
        .animation(.smooth(duration: 0.35), value: step)
        .animation(.smooth(duration: 0.3), value: errorMessage)
        .animation(.smooth(duration: 0.3), value: codePhase)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
        .errorFeedback(errorMessage)
        .feedback(.error, trigger: shakes)
        .feedback(.success, trigger: codePhase == .accepted) { _, accepted in accepted }
    }

    // MARK: - The card

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            switch step {
            case .email:
                LabelledField("Email") {
                    TextField("Email", text: $email, prompt: Text(verbatim: "adresse@exemple.fr"))
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .focused($emailFocused)
                        .onSubmit { Task { await send() } }
                }
                message
                PrimaryActionButton(isSending ? "Envoi…" : "Recevoir mon code") {
                    Task { await send() }
                }
                .disabled(!isValidEmail || isSending)
                .opacity(isValidEmail && !isSending ? 1 : 0.6)

            case .code(let address):
                VStack(alignment: .leading, spacing: 4) {
                    Text(codePhase == .accepted ? "C'est bon." : "Saisissez votre code")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .contentTransition(.opacity)
                    Text("Six chiffres, envoyés à \(address).")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                SmsCodeField(code: $code, phase: codePhase, shakes: shakes,
                             accessibilityLabel: "Code reçu par e-mail, six chiffres") { digits in
                    Task { await verify(digits, email: address) }
                }
                .disabled(codePhase == .checking || codePhase == .accepted)
                message
                HStack {
                    Button("Changer d'adresse") {
                        step = .email
                        code = ""
                        errorMessage = nil
                        resent = false
                        codePhase = .entering
                    }
                    .foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                    Button {
                        Task { await send(again: true) }
                    } label: {
                        if secondsBeforeResend > 0 {
                            Text("Renvoyer dans \(secondsBeforeResend) s")
                                .contentTransition(.numericText(countsDown: true))
                        } else {
                            Text("Renvoyer le code")
                        }
                    }
                    .foregroundStyle(secondsBeforeResend > 0 ? Theme.Palette.textSecondary
                                                             : Theme.Palette.brand)
                    .disabled(secondsBeforeResend > 0 || isSending)
                    .monospacedDigit()
                    .animation(.snappy, value: secondsBeforeResend)
                }
                .font(Theme.Typography.label)
            }
        }
        .padding(Theme.Spacing.cardPadding)
        .cardSurface()
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)))
        .id(step == .email ? "email" : "code")
    }

    @ViewBuilder
    private var message: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.destructive)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if resent {
            Label("Nouveau code envoyé.", systemImage: "paperplane.fill")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.successText)
                .transition(.opacity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Theme.Spacing.s) {
            Text("L'accès est réservé aux apporteurs invités par Trinity Énergie.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            // Sign-up is closed, so without this nobody uninvited -- a
            // prospect being shown the app, Apple's reviewers -- could see
            // anything.
            if onDemo != nil {
                Button { choosesDemo = true } label: {
                    Label("Découvrir l'application (démo)", systemImage: "sparkles")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.brand)
                }
                .confirmationDialog("Découvrir avec des données de démonstration",
                                    isPresented: $choosesDemo, titleVisibility: .visible) {
                    Button("Vue apporteur") { onDemo?(false) }
                    Button("Vue entreprise") { onDemo?(true) }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    Text("Aucune donnée réelle : les noms, montants et documents sont fictifs.")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    @MainActor
    private func send(again: Bool = false) async {
        guard isValidEmail, !isSending else { return }
        isSending = true
        defer { isSending = false }
        let address = email.trimmingCharacters(in: .whitespaces).lowercased()
        do {
            try await sendCode(address)
            errorMessage = nil
            code = ""
            codePhase = .entering
            resent = again
            // Auth refuses a second email inside a minute
            resendAvailableAt = .now.addingTimeInterval(60)
            emailFocused = false
            step = .code(address)
        } catch EmailCodeError.tooSoon where !again {
            // a code is already on its way: go and type it
            errorMessage = nil
            step = .code(address)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func verify(_ digits: String, email address: String) async {
        guard digits.count == 6, codePhase == .entering else { return }
        codePhase = .checking
        resent = false
        do {
            try await verifyCode(digits, address)
            errorMessage = nil
            codePhase = .accepted
        } catch {
            errorMessage = error.localizedDescription
            codePhase = .wrong
            shakes += 1
            try? await Task.sleep(for: .milliseconds(500))
            code = ""
            if codePhase == .wrong { codePhase = .entering }
        }
    }
}
