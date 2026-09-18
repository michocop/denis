import SwiftUI

/// The five-tab shell. One binary serves both populations: the tabs are the
/// same, and `role` decides which affordances appear inside them.
public struct RootView: View {
    public enum Tab: Hashable { case home, recommendations, catalogue, chat, profile }

    @State private var tab: Tab = .home
    @State private var showsCreate = false

    private let dependencies: Dependencies
    private let role: UserRole
    private let signerName: String
    private let onSignOut: () -> Void

    public init(dependencies: Dependencies, role: UserRole, signerName: String,
                onSignOut: @escaping () -> Void) {
        self.dependencies = dependencies
        self.role = role
        self.signerName = signerName
        self.onSignOut = onSignOut
    }

    public var body: some View {
        TabView(selection: $tab) {
            HomeView(model: HomeViewModel(profiles: dependencies.profiles)) {
                showsCreate = true
            }
            .tabItem { Label("Accueil", systemImage: "house") }
            .tag(Tab.home)

            RecommendationsView(
                model: RecommendationsViewModel(repository: dependencies.recommendations,
                                                role: role,
                                                changeMonitor: dependencies.changeMonitor),
                dependencies: dependencies,
                signerName: signerName
            )
            .tabItem { Label("Reco", systemImage: "doc.badge.plus") }
            .tag(Tab.recommendations)

            CatalogueView(
                model: CatalogueViewModel(repository: dependencies.catalogue, role: role)
            )
            .tabItem { Label("Catalogue", systemImage: "book") }
            .tag(Tab.catalogue)

            ChatView(model: ChatViewModel(repository: dependencies.chat))
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
            CreateRecommendationView(recommendations: dependencies.recommendations,
                                     catalogue: dependencies.catalogue) { _ in
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
