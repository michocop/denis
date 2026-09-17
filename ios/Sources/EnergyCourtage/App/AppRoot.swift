import SwiftUI
import Observation

/// Owns the session and decides what the app shows: sign-in, or the tabs.
@Observable
public final class AppModel {
    public enum State {
        case loading
        case signedOut(String?)
        case signedIn(Dependencies, UserRole, String)
    }

    public private(set) var state: State = .loading
    private var client: SupabaseClient?

    public init() {}

    @MainActor
    public func start() async {
        do {
            let config = try AppConfig.supabase()
            client = SupabaseClient(baseURL: config.url, anonKey: config.key)
            state = .signedOut(nil)
        } catch {
            state = .signedOut(error.localizedDescription)
        }
    }

    @MainActor
    public func signIn(email: String, password: String) async throws {
        guard let client else { throw SupabaseError.notConfigured }
        _ = try await client.signIn(email: email, password: password)

        let profiles = SupabaseProfileRepository(client: client)
        let profile = try await profiles.currentProfile()

        state = .signedIn(
            Dependencies(
                recommendations: SupabaseRecommendationsRepository(client: client),
                catalogue: SupabaseCatalogueRepository(client: client),
                chat: SupabaseChatRepository(client: client),
                profiles: profiles,
                invoices: SupabaseInvoiceRepository(client: client)
            ),
            profile.role,
            profile.fullName
        )
    }

    @MainActor
    public func signOut() async {
        await client?.signOut()
        state = .signedOut(nil)
    }
}

public struct AppRootView: View {
    @State private var model = AppModel()

    public init() {}

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()

            case .signedOut(let message):
                VStack(spacing: Theme.Spacing.m) {
                    SignInView { email, password in
                        try await model.signIn(email: email, password: password)
                    }
                    if let message {
                        Text(message)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                            .padding(.horizontal, Theme.Spacing.gutter)
                    }
                }

            case .signedIn(let dependencies, let role, let name):
                RootView(dependencies: dependencies, role: role, signerName: name) {
                    Task { await model.signOut() }
                }
            }
        }
        .task { await model.start() }
    }
}
