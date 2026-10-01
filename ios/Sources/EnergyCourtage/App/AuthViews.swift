import SwiftUI

/// Registration. There is no open sign-up: an apporteur is recruited, so the
/// code the company issued is the first field, and the role travels with it —
/// the client never asks to be anything.
public struct SignUpView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private let register: (String, String, String, String, String) async throws -> Void

    public init(register: @escaping (_ code: String, _ firstName: String, _ lastName: String,
                                     _ email: String, _ password: String) async throws -> Void) {
        self.register = register
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text("Vous avez reçu une invitation de votre interlocuteur ? Saisissez son code pour créer votre compte.")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LabelledField("Code d'invitation") {
                        TextField("XXXXXXXX", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(Theme.Typography.body.monospaced())
                    }
                    LabelledField("Prénom") {
                        TextField("Prénom", text: $firstName).textContentType(.givenName)
                    }
                    LabelledField("Nom") {
                        TextField("Nom", text: $lastName).textContentType(.familyName)
                    }
                    LabelledField("Email") {
                        TextField("adresse@exemple.fr", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabelledField("Mot de passe") {
                        SecureField("8 caractères minimum", text: $password)
                            .textContentType(.newPassword)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PrimaryActionButton(isWorking ? "Création…" : "Créer mon compte") {
                        Task { await submit() }
                    }
                    .disabled(!isValid || isWorking)
                    .opacity(isValid && !isWorking ? 1 : 0.5)
                }
                .padding(Theme.Spacing.gutter)
            }
            .background(Theme.Palette.canvas)
            .navigationTitle("Créer un compte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }

    private var isValid: Bool {
        !code.trimmingCharacters(in: .whitespaces).isEmpty
        && !firstName.trimmingCharacters(in: .whitespaces).isEmpty
        && !lastName.trimmingCharacters(in: .whitespaces).isEmpty
        && email.contains("@")
        && password.count >= 8
    }

    private func submit() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await register(code, firstName, lastName, email, password)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

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
        .background(Theme.Palette.canvas)
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
        .background(Theme.Palette.canvas)
    }
}

public struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var sent = false

    private let requestReset: (String) async -> Void

    public init(requestReset: @escaping (String) async -> Void) {
        self.requestReset = requestReset
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if sent {
                    // Deliberately says "if an account exists": confirming that
                    // an address is registered would leak the member list.
                    Text("Si un compte existe pour \(email), un lien de réinitialisation vient d'être envoyé.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    PrimaryActionButton("Fermer") { dismiss() }
                } else {
                    Text("Saisissez votre adresse : nous vous enverrons un lien pour choisir un nouveau mot de passe.")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LabelledField("Email") {
                        TextField("adresse@exemple.fr", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    PrimaryActionButton("Envoyer le lien") {
                        Task {
                            await requestReset(email)
                            sent = true
                        }
                    }
                    .disabled(!email.contains("@"))
                }
                Spacer()
            }
            .padding(Theme.Spacing.gutter)
            .background(Theme.Palette.canvas)
            .navigationTitle("Mot de passe oublié")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }
}

/// Shown over the tabs when a restored session is waiting on Face ID.
public struct LockedView: View {
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
        .background(Theme.Palette.canvas)
        .task { await unlock() }
    }
}
