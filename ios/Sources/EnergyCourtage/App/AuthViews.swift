import SwiftUI

/// Shown after registering against an invitation the company wants to vet.
public struct PendingApprovalView: View {
    private let email: String
    private let onSignOut: () -> Void
    private let onRefresh: () async -> Void

    public init(email: String, onRefresh: @escaping () async -> Void,
                onSignOut: @escaping () -> Void) {
        self.email = email
        self.onRefresh = onRefresh
        self.onSignOut = onSignOut
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer()
            Image(systemName: "hourglass")
                .font(.system(size: 44))
                .foregroundStyle(Theme.Palette.brand)
            Text("Compte en attente de validation")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text("Votre inscription avec \(email) a bien été enregistrée. Un membre de l'équipe doit la valider avant que vous puissiez accéder à vos recommandations.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            PrimaryActionButton("Vérifier à nouveau") { Task { await onRefresh() } }
            Button("Se déconnecter", action: onSignOut)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
        }
        .padding(Theme.Spacing.xl)
        .background(BrandBackground())
    }
}

/// Suspended, or an account whose personal data was erased on deletion.
public struct SuspendedView: View {
    private let onSignOut: () -> Void
    public init(onSignOut: @escaping () -> Void) { self.onSignOut = onSignOut }

    public var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer()
            Image(systemName: "lock.circle")
                .font(.system(size: 44))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("Accès suspendu")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Cet accès n'est plus actif. Contactez votre interlocuteur si vous pensez qu'il s'agit d'une erreur.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Se déconnecter", action: onSignOut)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.brand)
            Spacer()
        }
        .padding(Theme.Spacing.xl)
        .background(BrandBackground())
    }
}

/// Shown over the tabs when a restored session is waiting on Face ID.
public struct LockedView: View {
    /// Face ID is asked for once the opening has gone, not over it.
    @Environment(\.contentRevealed) private var revealed
    private let unlock: () async -> Void
    public init(unlock: @escaping () async -> Void) { self.unlock = unlock }

    public var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer()
            Image(systemName: "faceid")
                .font(.system(size: 48))
                .foregroundStyle(Theme.Palette.brand)
            Text("Espace verrouillé")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            PrimaryActionButton("Déverrouiller") { Task { await unlock() } }
                .frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandBackground())
        .task(id: revealed) {
            guard revealed else { return }
            await unlock()
        }
    }
}

/// The first sign-in of an invited address: the person says who they are,
/// and the invitation sent to that address gives them their role. Nothing
/// else to choose -- signing in is by emailed code, so there is no password.
public struct CompleteInviteView: View {
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @FocusState private var focus: Field?

    private enum Field { case first, last }

    private let email: String
    private let onSignOut: () -> Void
    private let complete: (String, String) async throws -> Void

    public init(email: String, onSignOut: @escaping () -> Void,
                complete: @escaping (_ firstName: String, _ lastName: String) async throws -> Void) {
        self.email = email
        self.onSignOut = onSignOut
        self.complete = complete
    }

    private var isValid: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty
        && !lastName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TrinityWordmark()
                Spacer()
                Button("Se déconnecter", action: onSignOut)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.top, Theme.Spacing.l)

            Spacer(minLength: Theme.Spacing.l)

            VStack(alignment: .leading, spacing: 2) {
                Text("Bienvenue chez")
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Trinity Énergie.")
                    .brandGradient()
            }
            .font(Theme.Typography.display(32, .semibold, relativeTo: .largeTitle))
            .minimumScaleFactor(0.8)
            .staggeredAppear(index: 0)

            if focus == nil {
                Text("Votre accès pour \(email) est ouvert. Dites-nous simplement comment vous appeler.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Spacing.m)
                    .transition(.opacity)
            }

            Spacer(minLength: Theme.Spacing.l)

            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                LabelledField("Prénom") {
                    TextField("Prénom", text: $firstName)
                        .textContentType(.givenName)
                        .submitLabel(.next)
                        .focused($focus, equals: .first)
                        .onSubmit { focus = .last }
                }
                LabelledField("Nom") {
                    TextField("Nom", text: $lastName)
                        .textContentType(.familyName)
                        .submitLabel(.join)
                        .focused($focus, equals: .last)
                        .onSubmit { Task { await submit() } }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PrimaryActionButton(isWorking ? "Un instant…" : "Rejoindre Trinity Énergie") {
                    Task { await submit() }
                }
                .disabled(!isValid || isWorking)
                .opacity(isValid && !isWorking ? 1 : 0.6)
            }
            .padding(Theme.Spacing.cardPadding)
            .cardSurface()
            .staggeredAppear(index: 1)

            Spacer(minLength: Theme.Spacing.m)
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BrandBackground())
        .animation(.smooth(duration: 0.3), value: focus)
        .animation(.smooth(duration: 0.3), value: errorMessage)
        .errorFeedback(errorMessage)
    }

    @MainActor
    private func submit() async {
        guard isValid, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await complete(firstName.trimmingCharacters(in: .whitespaces),
                               lastName.trimmingCharacters(in: .whitespaces))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
