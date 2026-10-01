import SwiftUI
import Observation

@Observable
public final class ProfileViewModel {
    public private(set) var profile: Profile?
    public private(set) var errorMessage: String?
    public var isWorking = false

    /// "Contact de Michel AJ" under the name: who invited this apporteur.
    public private(set) var contactName: String?
    public private(set) var saved = false

    private let repository: ProfileRepository
    private let documents: DocumentsRepository?
    public init(repository: ProfileRepository, documents: DocumentsRepository? = nil) {
        self.repository = repository
        self.documents = documents
    }

    @MainActor
    public func loadContact() async {
        contactName = try? await documents?.contactName()
    }

    /// "Compte": the fields a person may change about themselves. The phone
    /// number matters more than it looks: it is where signature codes go.
    @MainActor
    public func save(_ edited: Profile) async {
        isWorking = true
        defer { isWorking = false }
        do {
            profile = try await repository.save(edited)
            errorMessage = nil
            saved = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    public func load() async {
        do {
            profile = try await repository.currentProfile()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    public func deleteAccount() async {
        isWorking = true
        defer { isWorking = false }
        do { try await repository.deleteAccount() }
        catch { errorMessage = error.localizedDescription }
    }
}


/// "Profil": who you are, then one row per place to go — the layout of the
/// source app. The company keeps its two console rows above the shared ones.
public struct ProfileView: View {
    @State private var model: ProfileViewModel
    private let dependencies: Dependencies
    private let onSignOut: () -> Void

    public init(model: ProfileViewModel, dependencies: Dependencies,
                onSignOut: @escaping () -> Void) {
        _model = State(wrappedValue: model)
        self.dependencies = dependencies
        self.onSignOut = onSignOut
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.m) {
                    if let profile = model.profile {
                        header(profile)

                        NavigationLink {
                            AccountView(model: model, legal: dependencies.legal)
                        } label: {
                            row("Compte", "Informations personnelles", icon: "person")
                        }
                        NavigationLink {
                            DocumentsView(model: DocumentsViewModel(repository: dependencies.documents),
                                          invoices: dependencies.invoices,
                                          signerName: profile.fullName,
                                          isAdmin: profile.role.isAdmin)
                        } label: {
                            row("Mes documents", "Vos documents à portée de main",
                                icon: "doc.on.doc")
                        }
                        NavigationLink {
                            FAQView()
                        } label: {
                            row("F.A.Q", "Questions fréquentes", icon: "questionmark.circle")
                        }
                        NavigationLink {
                            LegalInfoView(legal: dependencies.legal)
                        } label: {
                            row("Informations légales", "Retrouvez les informations légales",
                                icon: "doc.text")
                        }

                        if profile.role.isAdmin {
                            NavigationLink {
                                MembersView(model: MembersViewModel(repository: dependencies.admin))
                            } label: {
                                row("Apporteurs", "Invitations et comptes", icon: "person.2")
                            }
                            NavigationLink {
                                PayablesView(model: PayablesViewModel(repository: dependencies.admin))
                            } label: {
                                row("À régler", "Récompenses à verser", icon: "eurosign.circle")
                            }
                        } else {
                            NavigationLink {
                                CommissionsView(
                                    model: CommissionsViewModel(repository: dependencies.commissions),
                                    apporteurName: profile.fullName
                                )
                            } label: {
                                row("Recommandations", "Montants potentiels et réalisés",
                                    icon: "building.columns")
                            }
                        }

                        Button(action: onSignOut) {
                            Text("Se déconnecter")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.destructive)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.Spacing.xl)
                        }
                        .buttonStyle(.plain)
                    } else if let message = model.errorMessage {
                        Text(message)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                            .padding(.vertical, 48)
                    } else {
                        ProgressView().padding(.vertical, 48)
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .task {
                await model.load()
                await model.loadContact()
            }
        }
    }

    private func header(_ profile: Profile) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(profile.initials)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Theme.Palette.textPrimary.opacity(0.7))
                .frame(width: 72, height: 72)
                .background(Circle().fill(Theme.Palette.avatar))
                .padding(.bottom, Theme.Spacing.s)
            Text(profile.fullName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            if profile.role.isAdmin {
                Text("Administrateur")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else if let contact = model.contactName {
                Text("Contact de \(contact)")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
    }

    private func row(_ title: String, _ subtitle: String, icon: String) -> some View {
        HStack(spacing: Theme.Spacing.l) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.Palette.brand)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(subtitle)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 15))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, 18)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
                .stroke(Theme.Palette.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Compte

/// What a person may change about themselves, the billing mandate, and the
/// account deletion the App Store requires to be reachable in the app.
public struct AccountView: View {
    private let model: ProfileViewModel
    @State private var draft: Profile?
    @State private var showsMandate = false
    @State private var confirmsDeletion = false
    private let legal: LegalRepository

    public init(model: ProfileViewModel, legal: LegalRepository) {
        self.model = model
        self.legal = legal
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if let profile = model.profile {
                    let binding = Binding<Profile>(
                        get: { draft ?? profile },
                        set: { draft = $0 }
                    )
                    LabelledField("Prénom") { TextField("Prénom", text: binding.firstName) }
                    LabelledField("Nom") { TextField("Nom", text: binding.lastName) }
                    LabelledField("E-mail") {
                        Text(profile.email).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        LabelledField("Téléphone mobile") {
                            TextField("06 12 34 56 78", text: Binding(
                                get: { binding.wrappedValue.phone ?? "" },
                                set: { binding.wrappedValue.phone = $0 }))
                                .keyboardType(.phonePad)
                                .textContentType(.telephoneNumber)
                        }
                        Text("Les codes de signature sont envoyés à ce numéro.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    LabelledField("Société") {
                        TextField("Optionnel", text: Binding(
                            get: { binding.wrappedValue.companyName ?? "" },
                            set: { binding.wrappedValue.companyName = $0 }))
                    }
                    LabelledField("SIRET") {
                        TextField("Optionnel", text: Binding(
                            get: { binding.wrappedValue.siret ?? "" },
                            set: { binding.wrappedValue.siret = $0 }))
                            .keyboardType(.numberPad)
                    }
                    LabelledField("Ville") {
                        TextField("Ville", text: Binding(
                            get: { binding.wrappedValue.city ?? "" },
                            set: { binding.wrappedValue.city = $0 }))
                    }

                    PrimaryActionButton(model.isWorking ? "Enregistrement…" : "Enregistrer") {
                        if let draft { Task { await model.save(draft); self.draft = nil } }
                    }
                    .disabled(draft == nil || model.isWorking)
                    .opacity(draft == nil ? 0.5 : 1)

                    if model.saved && draft == nil {
                        Label("Enregistré", systemImage: "checkmark.circle.fill")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Palette.successText)
                    }

                    if !profile.role.isAdmin { billing(profile) }

                    Button(role: .destructive) { confirmsDeletion = true } label: {
                        Text("Supprimer mon compte")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.destructive)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                }

                if let message = model.errorMessage {
                    Text(message)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.destructive)
                }
            }
            .padding(Theme.Spacing.gutter)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("Compte")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsMandate) {
            LegalDocumentView(model: LegalViewModel(repository: legal),
                              documentKey: "mandat_facturation")
                .onDisappear { Task { await model.load() } }
        }
        .confirmationDialog("Supprimer définitivement votre compte ?",
                            isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { Task { await model.deleteAccount() } }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Vos recommandations et vos factures sont conservées pour des raisons légales, mais votre compte et vos données personnelles seront supprimés.")
        }
    }

    private func billing(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Facturation")
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            HStack {
                Text("Régime de TVA")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text(profile.vatLiable ? "Assujetti (20 %)" : "Franchise en base (293 B)")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            Divider()
            if profile.canBeInvoiced {
                Label("Mandat de facturation signé", systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.successText)
            } else {
                Text("Le mandat autorise Trinity Énergie à établir vos reconnaissances d'honoraires en votre nom. Il doit être signé avant toute facturation.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                // Opens the document rather than signing from a summary, so
                // the consent recorded is to something actually shown.
                PrimaryActionButton("Lire et signer le mandat") { showsMandate = true }
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

// MARK: - Informations légales

public struct LegalInfoView: View {
    @State private var opened: String?
    private let legal: LegalRepository

    public init(legal: LegalRepository) { self.legal = legal }

    private struct Entry: Identifiable { let id: String; let title: String }
    private let entries = [
        Entry(id: "cgu", title: "Conditions générales d'utilisation"),
        Entry(id: "confidentialite", title: "Politique de confidentialité"),
        Entry(id: "mandat_facturation", title: "Mandat de facturation")
    ]

    public var body: some View {
        List(entries) { entry in
            Button(entry.title) { opened = entry.id }
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .navigationTitle("Informations légales")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { opened.map(LegalKey.init) },
                             set: { opened = $0?.id })) { key in
            LegalDocumentView(model: LegalViewModel(repository: legal), documentKey: key.id)
        }
    }

    private struct LegalKey: Identifiable { let id: String }
}

// MARK: - F.A.Q

public struct FAQView: View {
    public init() {}

    struct Entry: Identifiable {
        let question: String
        let answer: String
        var id: String { question }
        init(_ question: String, _ answer: String) { self.question = question; self.answer = answer }
    }

    static let entries: [Entry] = [
        Entry("Comment recommander quelqu'un ?",
         "Dans l'onglet Reco, touchez « + », renseignez les coordonnées de la personne et confirmez qu'elle est d'accord pour être contactée. Nous la rappelons rapidement et vous suivez chaque étape dans l'application."),
        Entry("Quand ma récompense est-elle acquise ?",
         "Dès que la prestation est signée par la personne recommandée. L'étape « Devis signé » passe alors au vert et le montant de votre récompense s'affiche."),
        Entry("Comment suis-je payé ?",
         "Une reconnaissance d'honoraires est établie en votre nom. Vous la signez dans l'application avec un code reçu par SMS, puis la récompense est versée selon le mode indiqué : virement, chèque, carte cadeau ou avoir."),
        Entry("Pourquoi signer un mandat de facturation ?",
         "Il autorise Trinity Énergie à établir vos reconnaissances d'honoraires à votre place. Sans lui, la loi ne nous permet pas de vous payer."),
        Entry("Pourquoi envoyer ma carte d'identité et mon RIB ?",
         "Pour vérifier qui nous payons et sur quel compte. Ces fichiers sont supprimés automatiquement 30 jours après leur envoi."),
        Entry("Dois-je déclarer mes récompenses ?",
         "Oui. Si vous êtes apporteur d'affaires occasionnel, déclarez les sommes perçues au titre des bénéfices non commerciaux (BNC) sur votre déclaration de revenus, formulaire CERFA 2042 C PRO."),
        Entry("Je n'ai pas reçu le code de signature",
         "Vérifiez le numéro de mobile dans Profil › Compte, puis touchez « Renvoyer le code ». Un nouveau code peut être demandé chaque minute.")
    ]

    public var body: some View {
        List {
            ForEach(Self.entries) { entry in
                DisclosureGroup {
                    Text(entry.answer)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Theme.Spacing.xs)
                } label: {
                    Text(entry.question)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
            }
        }
        .navigationTitle("Questions fréquentes")
        .navigationBarTitleDisplayMode(.inline)
    }
}
