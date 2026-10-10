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

            // No banner in the demo: the way in ("Découvrir l'application")
            // already says, before anything is shown, that the data is fictitious.
            tabs
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

/// Email/password sign-in. Signup is invitation-based in this product, so the
/// screen offers no self-registration.
public struct SignInView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    @State private var choosesDemo = false

    private let signIn: (String, String) async throws -> Void
    private let onCreateAccount: () -> Void
    private let onForgotPassword: () -> Void
    /// Opens the app on sample data, as an apporteur (false) or as the company.
    private let onDemo: ((Bool) -> Void)?

    public init(signIn: @escaping (String, String) async throws -> Void,
                onCreateAccount: @escaping () -> Void,
                onForgotPassword: @escaping () -> Void,
                onDemo: ((Bool) -> Void)? = nil) {
        self.signIn = signIn
        self.onCreateAccount = onCreateAccount
        self.onForgotPassword = onForgotPassword
        self.onDemo = onDemo
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                TrinityWordmark()
                    .padding(.top, Theme.Spacing.xl)
                    .staggeredAppear(index: 0)

                // the site's headline: white, then the blue gradient
                VStack(alignment: .leading, spacing: 2) {
                    Text("Votre espace")
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("apporteur d'affaires.")
                        .brandGradient()
                }
                .font(Theme.Typography.display(34, .semibold, relativeTo: .largeTitle))
                .padding(.top, 36)
                .staggeredAppear(index: 1)

                Text("Suivez vos recommandations, signez vos factures et recevez vos commissions.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .staggeredAppear(index: 2)

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
                .staggeredAppear(index: 3)

                SecondaryActionButton("J'ai reçu une invitation", systemImage: "envelope.open",
                                      action: onCreateAccount)
                    .staggeredAppear(index: 4)

                Text("L'accès est réservé aux apporteurs invités par Trinity Énergie.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                // Sign-up is closed, so without this nobody uninvited -- a
                // prospect being shown the app, Apple's reviewers -- could
                // see anything. Sample data only, said so on every screen.
                if onDemo != nil {
                    Button { choosesDemo = true } label: {
                        Label("Découvrir l'application (démo)", systemImage: "sparkles")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.brand)
                            .frame(maxWidth: .infinity)
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
            .padding(Theme.Spacing.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(BrandBackground())
        .errorFeedback(errorMessage)
    }
}
