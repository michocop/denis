import SwiftUI
import QuickLook
import Observation

@Observable
public final class SignedContractsViewModel {
    public private(set) var contracts: [SignedContract] = []
    public private(set) var hasLoaded = false
    public private(set) var errorMessage: String?

    let repository: SignedContractsRepository
    public init(repository: SignedContractsRepository) { self.repository = repository }

    public var book: ContractBook { ContractBook(contracts) }
    public var isEmpty: Bool { hasLoaded && contracts.isEmpty }

    @MainActor
    public func load() async {
        do {
            contracts = try await repository.contracts()
            hasLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Throws, so the form that asked stays open with the reason.
    @MainActor
    @discardableResult
    public func save(_ contract: SignedContract) async throws -> SignedContract {
        let saved = try await repository.save(contract)
        if let index = contracts.firstIndex(where: { $0.id == saved.id }) {
            contracts[index] = saved
        } else {
            contracts.append(saved)
        }
        return saved
    }

    @MainActor
    public func delete(_ contract: SignedContract) async throws {
        try await repository.delete(id: contract.id)
        contracts.removeAll { $0.id == contract.id }
    }

    public func contract(_ id: UUID) -> SignedContract? { contracts.first { $0.id == id } }
}

// MARK: - The list

/// The owner's book: every contract signed, the next échéance first.
public struct SignedContractsView: View {
    @State private var model: SignedContractsViewModel
    @State private var creating: SignedContract?

    public init(model: SignedContractsViewModel) { _model = State(wrappedValue: model) }

    public var body: some View {
        ZStack {
            BrandBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text("Contrats signés")
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.top, Theme.Spacing.s)

                    PrimaryActionButton("Ajouter un contrat") { creating = SignedContract() }

                    content

                    if let message = model.errorMessage {
                        Text(message)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .refreshable { await model.load() }
        }
        .task { await model.load() }
        .sheet(item: $creating) { draft in
            SignedContractForm(contract: draft, isNew: true) { try await model.save($0) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isEmpty {
            VStack(spacing: Theme.Spacing.m) {
                Image(systemName: "doc.text")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("Aucun contrat enregistré.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Ajoutez les contrats signés : ils seront classés par date d'échéance.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if !model.hasLoaded {
            if model.errorMessage == nil {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 56)
            }
        } else {
            let book = model.book
            section("Prochaines échéances", book.upcoming)
            section("Sans date d'échéance", book.undated)
            section("Échéance passée", book.expired)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ contracts: [SignedContract]) -> some View {
        if !contracts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text(title)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                ForEach(contracts) { contract in
                    NavigationLink {
                        SignedContractDetailView(model: model, contractID: contract.id)
                    } label: {
                        SignedContractRow(contract: contract)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct SignedContractRow: View {
    let contract: SignedContract

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text(contract.clientName)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                if let badge = EcheanceBadge(contract.endsOn) { badge }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = [contract.energy.label]
        if let supplier = contract.newSupplier?.nonBlank { parts.append(supplier) }
        if let city = contract.city?.nonBlank { parts.append(city) }
        return parts.joined(separator: " · ")
    }
}

/// "Échéance le 31 mars 2027 · dans 135 jours", amber inside three months,
/// red once past.
struct EcheanceBadge: View {
    let text: String
    let tint: Color
    let fill: Color

    init?(_ day: String?, now: Date = .now) {
        guard let long = ContractDay.long(day),
              let days = ContractDay.daysUntil(day, from: now) else { return nil }
        let when: String
        switch days {
        case ..<0:  when = "dépassée depuis \(-days) j"
        case 0:     when = "aujourd'hui"
        case 1:     when = "demain"
        default:    when = "dans \(days) jours"
        }
        text = "Échéance le \(long) · \(when)"
        if days < 0 {
            tint = Theme.Palette.destructive; fill = Theme.Palette.destructive.opacity(0.14)
        } else if days <= 90 {
            tint = Theme.Palette.staleText; fill = Theme.Palette.staleSoft
        } else {
            tint = Theme.Palette.successText; fill = Theme.Palette.successSoft
        }
    }

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
    }
}

// MARK: - One contract

struct SignedContractDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let model: SignedContractsViewModel
    let contractID: UUID

    @State private var editing: SignedContract?
    @State private var letterURL: URL?
    @State private var confirmsDeletion = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            BrandBackground()
            if let contract = model.contract(contractID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(contract.clientName)
                                .font(Theme.Typography.screenTitle)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text(contract.isProfessional ? "Professionnel" : "Particulier")
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            if let badge = EcheanceBadge(contract.endsOn) { badge }
                        }
                        .padding(.top, Theme.Spacing.s)

                        letterCard(contract)

                        card("Client", rows: [
                            ("Signataire", [contract.signatoryName?.nonBlank, contract.signatoryTitle?.nonBlank]
                                .compactMap { $0 }.joined(separator: ", ").nonBlank),
                            ("SIRET", contract.siret),
                            ("Adresse", contract.postalAddress),
                            ("Téléphone", contract.phone),
                            ("Email", contract.email),
                        ])
                        card("Contrat signé", rows: [
                            ("Énergie", contract.energy.label),
                            (contract.energy.deliveryPointLabel, contract.deliveryPoint),
                            ("Site", contract.siteAddress),
                            ("Nouveau fournisseur", contract.newSupplier),
                            ("Signé le", ContractDay.long(contract.signedOn)),
                            ("Début", ContractDay.long(contract.startsOn)),
                            ("Échéance", ContractDay.long(contract.endsOn)),
                        ])
                        card("Ancien contrat", rows: [
                            ("Fournisseur", contract.previousSupplier),
                            ("Adresse", contract.previousSupplierAddress),
                            ("N° client / contrat", contract.previousReference),
                            ("Résiliation au", ContractDay.long(contract.terminationOn)),
                        ])
                        card("Notes", rows: [("", contract.notes)])

                        if let errorMessage {
                            Text(errorMessage)
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Palette.destructive)
                        }

                        SecondaryActionButton("Modifier", systemImage: "pencil") { editing = contract }
                        Button(role: .destructive) { confirmsDeletion = true } label: {
                            Text("Supprimer ce contrat")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.destructive)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.gutter)
                    .padding(.bottom, Theme.Spacing.xl)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { draft in
            SignedContractForm(contract: draft, isNew: false) { try await model.save($0) }
        }
        .quickLookPreview($letterURL)
        .confirmationDialog("Supprimer ce contrat ?", isPresented: $confirmsDeletion,
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                Task {
                    guard let contract = model.contract(contractID) else { return }
                    do {
                        try await model.delete(contract)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Il disparaîtra définitivement de votre liste.")
        }
    }

    private func letterCard(_ contract: SignedContract) -> some View {
        let missing = TerminationLetter.missing(in: contract)
        let canWrite = TerminationLetter.canWrite(contract)
        return VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Label("Lettre de résiliation", systemImage: "envelope")
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(canWrite
                 ? "Prête à signer par le client et à envoyer en recommandé à \(contract.previousSupplier ?? "l'ancien fournisseur")."
                 : "Renseignez l'ancien fournisseur pour générer la lettre.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if canWrite && !missing.isEmpty {
                Text("À compléter pour une lettre complète : " + missing.joined(separator: ", ") + ".")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.staleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PrimaryActionButton("Générer la lettre") { letterURL = writeLetter(contract) }
                .disabled(!canWrite)
                .opacity(canWrite ? 1 : 0.5)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func writeLetter(_ contract: SignedContract) -> URL? {
        let data = TerminationLetterPDF.render(TerminationLetter(contract: contract))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(TerminationLetter.filename(for: contract))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @ViewBuilder
    private func card(_ title: String, rows: [(String, String?)]) -> some View {
        let filled = rows.compactMap { label, value in value?.nonBlank.map { (label, $0) } }
        if !filled.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text(title)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                ForEach(Array(filled.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 2) {
                        if !row.0.isEmpty {
                            Text(row.0)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Text(row.1)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }
}

// MARK: - The form

struct SignedContractForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SignedContract
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let isNew: Bool
    private let save: (SignedContract) async throws -> SignedContract

    init(contract: SignedContract, isNew: Bool,
         save: @escaping (SignedContract) async throws -> SignedContract) {
        _draft = State(initialValue: contract)
        self.isNew = isNew
        self.save = save
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    group("Client")
                    Picker("Type de client", selection: $draft.clientKind) {
                        Text("Professionnel").tag(SignedContract.ClientKind.professionnel)
                        Text("Particulier").tag(SignedContract.ClientKind.particulier)
                    }
                    .pickerStyle(.segmented)

                    LabelledField(draft.isProfessional ? "Raison sociale" : "Nom et prénom") {
                        TextField(draft.isProfessional ? "Boulangerie Martin" : "Thomas Dubois",
                                  text: $draft.clientName)
                            .textContentType(draft.isProfessional ? .organizationName : .name)
                    }
                    if draft.isProfessional {
                        LabelledField("Signataire (facultatif)") {
                            TextField("Prénom Nom", text: text(\.signatoryName))
                                .textContentType(.name)
                        }
                        LabelledField("Fonction du signataire (facultatif)") {
                            TextField("Gérant, Président…", text: text(\.signatoryTitle))
                        }
                        LabelledField("SIRET (facultatif)") {
                            TextField("14 chiffres", text: text(\.siret))
                                .keyboardType(.numberPad)
                        }
                    }
                    LabelledField("Adresse") {
                        TextField("Numéro et rue", text: text(\.address))
                            .textContentType(.streetAddressLine1)
                    }
                    HStack(spacing: Theme.Spacing.m) {
                        LabelledField("Code postal") {
                            TextField("59000", text: text(\.postalCode))
                                .keyboardType(.numberPad)
                                .textContentType(.postalCode)
                        }
                        .frame(maxWidth: 130)
                        LabelledField("Ville") {
                            TextField("Ville", text: text(\.city))
                                .textContentType(.addressCity)
                        }
                    }
                    LabelledField("Téléphone (facultatif)") {
                        TextField("06 12 34 56 78", text: text(\.phone))
                            .keyboardType(.phonePad)
                    }
                    LabelledField("Email (facultatif)") {
                        TextField("Email", text: text(\.email),
                                  prompt: Text(verbatim: "client@exemple.fr"))
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    group("Contrat signé")
                    Picker("Énergie", selection: $draft.energy) {
                        ForEach(SignedContract.Energy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabelledField(draft.energy.deliveryPointLabel) {
                        TextField(draft.energy == .electricite ? "14 chiffres" : "GI ou 14 chiffres",
                                  text: text(\.deliveryPoint))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                    LabelledField("Adresse du site (si différente)") {
                        TextField("Adresse du point de livraison", text: text(\.siteAddress))
                    }
                    LabelledField("Nouveau fournisseur") {
                        TextField("Fournisseur choisi", text: text(\.newSupplier))
                    }
                    DayField("Date de signature", day: $draft.signedOn)
                    DayField("Début du contrat", day: $draft.startsOn)
                    DayField("Échéance du contrat", day: $draft.endsOn)

                    group("Ancien contrat (pour la lettre de résiliation)")
                    LabelledField("Ancien fournisseur") {
                        TextField("EDF, Engie…", text: text(\.previousSupplier))
                    }
                    LabelledField("Adresse de résiliation du fournisseur") {
                        TextField("Service, adresse, code postal et ville",
                                  text: text(\.previousSupplierAddress), axis: .vertical)
                            .lineLimit(2...5)
                    }
                    LabelledField("N° client ou de contrat") {
                        TextField("Sur la facture de l'ancien fournisseur", text: text(\.previousReference))
                            .autocorrectionDisabled()
                    }
                    DayField("Résiliation à compter du", day: $draft.terminationOn)

                    group("Notes")
                    LabelledField("Notes (facultatif)") {
                        TextField("Conditions, rappel prévu…", text: text(\.notes), axis: .vertical)
                            .lineLimit(3...8)
                    }

                    if let problem = validationProblem ?? errorMessage {
                        Text(problem)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Palette.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PrimaryActionButton(isSaving ? "Enregistrement…" : "Enregistrer") {
                        Task { await submit() }
                    }
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
                }
                .padding(Theme.Spacing.gutter)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(BrandBackground())
            .navigationTitle(isNew ? "Nouveau contrat" : "Modifier le contrat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }

    private var canSave: Bool {
        !isSaving && validationProblem == nil
            && !draft.clientName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var validationProblem: String? {
        let siret = (draft.siret ?? "").filter { !$0.isWhitespace }
        if draft.isProfessional && !siret.isEmpty && (siret.count != 14 || !siret.allSatisfy(\.isNumber)) {
            return "Le SIRET compte 14 chiffres."
        }
        let postalCode = (draft.postalCode ?? "").trimmingCharacters(in: .whitespaces)
        if !postalCode.isEmpty && (postalCode.count != 5 || !postalCode.allSatisfy(\.isNumber)) {
            return "Le code postal compte 5 chiffres."
        }
        if let start = draft.startsOn, let end = draft.endsOn, end < start {
            return "L'échéance ne peut pas précéder le début du contrat."
        }
        return nil
    }

    private func group(_ title: String) -> some View {
        Text(title)
            .font(Theme.Typography.body.weight(.semibold))
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.top, Theme.Spacing.s)
    }

    private func text(_ keyPath: WritableKeyPath<SignedContract, String?>) -> Binding<String> {
        Binding(get: { draft[keyPath: keyPath] ?? "" },
                set: { draft[keyPath: keyPath] = $0 })
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        var contract = draft
        // A particulier has no signatory or SIRET: drop what was typed before
        // the type was switched, or it would print on the letter.
        if !contract.isProfessional {
            contract.signatoryName = nil; contract.signatoryTitle = nil; contract.siret = nil
        }
        do {
            _ = try await save(contract)
            dismiss()
        } catch {
            errorMessage = "Le contrat n'a pas pu être enregistré : " + error.localizedDescription
        }
    }
}

/// An optional calendar day: a switch, then the date.
struct DayField: View {
    let label: String
    @Binding var day: String?

    init(_ label: String, day: Binding<String?>) {
        self.label = label
        _day = day
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Toggle(isOn: Binding(
                get: { day != nil },
                set: { day = $0 ? (day ?? ContractDay.string(.now)) : nil }
            )) {
                Text(label)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .tint(Theme.Palette.brandFill)
            if day != nil {
                DatePicker(label, selection: Binding(
                    get: { ContractDay.date(day) ?? .now },
                    set: { day = ContractDay.string($0) }
                ), displayedComponents: .date)
                .labelsHidden()
                .tint(Theme.Palette.brand)
                .environment(\.locale, Locale(identifier: "fr_FR"))
            }
        }
    }
}
