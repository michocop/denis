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
    /// False once the account exists and only the invitation is missing: the
    /// person is already signed in, so asking for an email and password again
    /// would only create a second account, or fail trying.
    private let asksForCredentials: Bool
    private let onCancel: (() -> Void)?

    public init(asksForCredentials: Bool = true,
                onCancel: (() -> Void)? = nil,
                register: @escaping (_ code: String, _ firstName: String, _ lastName: String,
                                     _ email: String, _ password: String) async throws -> Void) {
        self.asksForCredentials = asksForCredentials
        self.onCancel = onCancel
        self.register = register
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text(asksForCredentials
                         ? "Vous avez reçu une invitation de votre interlocuteur ? Saisissez son code pour créer votre compte."
                         : "Votre compte est créé. Saisissez le code d'invitation reçu de votre interlocuteur pour y accéder.")
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
                    if asksForCredentials {
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
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PrimaryActionButton(isWorking ? "Création…"
                                        : (asksForCredentials ? "Créer mon compte" : "Valider mon invitation")) {
                        Task { await submit() }
                    }
                    .disabled(!isValid || isWorking)
                    .opacity(isValid && !isWorking ? 1 : 0.5)
                }
                .padding(Theme.Spacing.gutter)
            }
            .background(BrandBackground())
            .navigationTitle(asksForCredentials ? "Créer un compte" : "Code d'invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(onCancel == nil ? "Annuler" : "Se déconnecter") {
                        if let onCancel { onCancel() } else { dismiss() }
                    }
                }
            }
        }
    }

    private var isValid: Bool {
        !code.trimmingCharacters(in: .whitespaces).isEmpty
        && !firstName.trimmingCharacters(in: .whitespaces).isEmpty
        && !lastName.trimmingCharacters(in: .whitespaces).isEmpty
        && (!asksForCredentials || (email.contains("@") && password.count >= 8))
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

/// Shown after signing up on a project that confirms addresses by email.
public struct AwaitingConfirmationView: View {
    private let email: String
    private let onContinue: () -> Void

    public init(email: String, onContinue: @escaping () -> Void) {
        self.email = email
        self.onContinue = onContinue
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer()
            Image(systemName: "envelope.badge")
                .font(.system(size: 44))
                .foregroundStyle(Theme.Palette.brand)
            Text("Confirmez votre adresse")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text("Un e-mail vient d'être envoyé à \(email). Ouvrez le lien qu'il contient, puis connectez-vous : votre code d'invitation vous sera demandé une dernière fois.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryActionButton("Me connecter", action: onContinue)
            Spacer()
        }
        .padding(Theme.Spacing.xl)
        .background(BrandBackground())
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
            .background(BrandBackground())
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
        .background(BrandBackground())
        .task { await unlock() }
    }
}

/// The end of a password reset: the emailed link has signed the person in,
/// and this is where they choose the new password. Before it existed the
/// reset could be requested but never finished.
public struct NewPasswordView: View {
    @State private var password = ""
    @State private var confirmation = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private let save: (String) async throws -> Void

    public init(save: @escaping (String) async throws -> Void) {
        self.save = save
    }

    private var problem: String? {
        if password.count < 8 { return "8 caractères minimum." }
        if confirmation != password { return "Les deux mots de passe ne correspondent pas." }
        return nil
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                TrinityWordmark()
                    .padding(.top, Theme.Spacing.xl)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Choisissez un")
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("nouveau mot de passe.")
                        .brandGradient()
                }
                .font(Theme.Typography.display(30, .semibold, relativeTo: .largeTitle))
                .padding(.top, 24)

                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    LabelledField("Nouveau mot de passe") {
                        SecureField("8 caractères minimum", text: $password)
                            .textContentType(.newPassword)
                    }
                    LabelledField("Confirmation") {
                        SecureField("Le même, une seconde fois", text: $confirmation)
                            .textContentType(.newPassword)
                    }
                    if let message = errorMessage ?? (confirmation.isEmpty ? nil : problem) {
                        Text(message)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    PrimaryActionButton(isWorking ? "Enregistrement…" : "Enregistrer") {
                        Task {
                            isWorking = true
                            defer { isWorking = false }
                            do { try await save(password) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(problem != nil || isWorking)
                    .opacity(problem != nil ? 0.6 : 1)
                }
                .padding(Theme.Spacing.cardPadding)
                .cardSurface()
            }
            .padding(Theme.Spacing.gutter)
        }
        .background(BrandBackground())
    }
}


/// The invited person's first screen: their name and a password. The email
/// they came from is the invitation; nothing else is asked.
public struct CompleteInviteView: View {
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private let email: String
    private let complete: (String, String, String) async throws -> Void

    public init(email: String, complete: @escaping (String, String, String) async throws -> Void) {
        self.email = email
        self.complete = complete
    }

    private var isValid: Bool {
        !firstName.trimmingCharacters(in: .whitespaces).isEmpty
        && !lastName.trimmingCharacters(in: .whitespaces).isEmpty
        && password.count >= 8
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                TrinityWordmark()
                    .padding(.top, Theme.Spacing.xl)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Bienvenue chez")
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Trinity Énergie.")
                        .brandGradient()
                }
                .font(Theme.Typography.display(32, .semibold, relativeTo: .largeTitle))
                .padding(.top, 24)

                Text("Votre invitation pour \(email) est valable. Il ne reste qu'à vous présenter et choisir un mot de passe.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    LabelledField("Prénom") {
                        TextField("Prénom", text: $firstName).textContentType(.givenName)
                    }
                    LabelledField("Nom") {
                        TextField("Nom", text: $lastName).textContentType(.familyName)
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
                    PrimaryActionButton(isWorking ? "Création…" : "Rejoindre Trinity Énergie") {
                        Task {
                            isWorking = true
                            defer { isWorking = false }
                            do { try await complete(firstName, lastName, password) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(!isValid || isWorking)
                    .opacity(isValid ? 1 : 0.6)
                }
                .padding(Theme.Spacing.cardPadding)
                .cardSurface()
            }
            .padding(Theme.Spacing.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(BrandBackground())
    }
}

/// What "J'ai reçu une invitation" explains, now that nobody can sign up
/// without one: the invitation is an email, and its link opens the app.
public struct InvitationHelpView: View {
    @Environment(\.dismiss) private var dismiss
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Image(systemName: "envelope.open.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Palette.brand)
            Text("Votre invitation est dans votre boîte mail")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Ouvrez l'e-mail de Trinity Énergie sur cet iPhone et touchez le lien : l'application s'ouvre pour que vous choisissiez votre mot de passe. Vous ne le trouvez pas ? Regardez dans les indésirables, ou demandez à votre interlocuteur de vous l'envoyer à nouveau.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryActionButton("Compris") { dismiss() }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(BrandBackground())
    }
}
