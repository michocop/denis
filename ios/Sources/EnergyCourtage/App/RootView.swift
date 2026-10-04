import SwiftUI

/// The four-tab shell. One binary serves both populations: the tabs are the
/// same, and `role` decides which affordances appear inside them.
public struct RootView: View {
    public enum Tab: Hashable { case home, recommendations, chat, profile }

    @State private var tab: Tab = .home
    @State private var showsCreate = false
    @State private var showsNotifications = false
    @State private var notifications: NotificationsViewModel
    @State private var connectivity = Connectivity()
    @State private var legal: LegalViewModel
    @State private var requiredDocument: LegalDocumentKey?
    /// An invoice opened from a notification, over whatever tab is showing.
    @State private var openedInvoice: OpenedInvoice?
    private var push = PushCenter.shared

    private struct OpenedInvoice: Identifiable {
        let id: UUID
    }

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
        guard !isDemo else { return }
        await legal.load()
        // Offline, the last list is all there is; presenting from it would
        // reopen the sheet every time it was closed.
        guard legal.errorMessage == nil else { return }
        requiredDocument = legal.outstanding
            .first { Self.requiredDocuments.contains($0.key) }
            .map { LegalDocumentKey(id: $0.key) }
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

            // Said out loud, because the sample data contains plausible names
            // and four-figure commissions, and nobody should have to guess
            // whether what they are looking at is real.
            if isDemo {
                Text("Données de démonstration — \(role.isAdmin ? "vue entreprise" : "vue apporteur")")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.rewardText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Theme.Palette.rewardSoft)
            }
            tabs
        }
        .animation(.snappy, value: connectivity.isOnline)
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
        .task {
            // Asked for here rather than at launch: a permission prompt on the
            // first screen, before the app has done anything, is the one
            // people decline.
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
                                                    repository: dependencies.invoices),
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

    private var tabs: some View {
        TabView(selection: $tab) {
            NavigationStack {
                HomeView(model: HomeViewModel(profiles: dependencies.profiles)) {
                    showsCreate = true
                }
                .toolbar { notificationsButton }
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
        .sheet(isPresented: $showsCreate) {
            CreateRecommendationView(recommendations: dependencies.recommendations) { _ in
                tab = .recommendations
            }
        }
    }
}

/// Email/password sign-in. Signup is invitation-based in this product, so the
/// screen offers no self-registration.
public struct SignInView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private let signIn: (String, String) async throws -> Void
    private let onCreateAccount: () -> Void
    private let onForgotPassword: () -> Void

    public init(signIn: @escaping (String, String) async throws -> Void,
                onCreateAccount: @escaping () -> Void,
                onForgotPassword: @escaping () -> Void) {
        self.signIn = signIn
        self.onCreateAccount = onCreateAccount
        self.onForgotPassword = onForgotPassword
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                TrinityWordmark()
                    .padding(.top, Theme.Spacing.xl)

                // the site's headline: white, then the blue gradient
                VStack(alignment: .leading, spacing: 2) {
                    Text("Votre espace")
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("apporteur d'affaires.")
                        .brandGradient()
                }
                .font(Theme.Typography.display(34, .semibold, relativeTo: .largeTitle))
                .padding(.top, 36)

                Text("Suivez vos recommandations, signez vos factures et recevez vos commissions.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    LabelledField("Email") {
                        TextField("adresse@exemple.fr", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabelledField("Mot de passe") {
                        SecureField("••••••••", text: $password)
                            .textContentType(.password)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PrimaryActionButton(isWorking ? "Connexion…" : "Se connecter") {
                        Task {
                            isWorking = true
                            defer { isWorking = false }
                            do {
                                try await signIn(email, password)
                                errorMessage = nil
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || isWorking)
                    .opacity(email.isEmpty || password.isEmpty ? 0.6 : 1)

                    Button("Mot de passe oublié ?", action: onForgotPassword)
                        .font(Theme.Typography.secondary.weight(.semibold))
                        .foregroundStyle(Theme.Palette.brand)
                        .frame(maxWidth: .infinity)
                }
                .padding(Theme.Spacing.cardPadding)
                .cardSurface()

                SecondaryActionButton("J'ai un code d'invitation", systemImage: "ticket",
                                      action: onCreateAccount)

                Text("L'accès est réservé aux apporteurs invités par Trinity Énergie.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(Theme.Spacing.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(BrandBackground())
    }
}
