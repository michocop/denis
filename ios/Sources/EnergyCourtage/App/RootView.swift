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
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Said plainly, because a request that fails with no signal used
            // to come back as "Une erreur est survenue" — which reads as "the
            // app is broken" to someone standing in a client's basement.
            if !connectivity.isOnline {
                Label("Hors ligne — les modifications attendront le réseau",
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
        .task {
            // Asked for here rather than at launch: a permission prompt on the
            // first screen, before the app has done anything, is the one
            // people decline.
            await LocalNotifications.requestPermission()
            PushRegistration.registerIfAvailable()
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
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Spacer()
            Text("Connexion")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Palette.textPrimary)

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

            HStack {
                Button("Mot de passe oublié ?", action: onForgotPassword)
                Spacer()
                Button("J'ai un code d'invitation", action: onCreateAccount)
            }
            .font(Theme.Typography.secondary)
            .foregroundStyle(Theme.Palette.brand)

            Text("L'accès est réservé aux apporteurs invités par Trinity Énergie.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(Theme.Spacing.gutter)
        .background(Theme.Palette.canvas)
    }
}
