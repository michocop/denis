import SwiftUI
import QuickLook
import Observation

@Observable
public final class SignedContractsViewModel {
    public private(set) var contracts: [SignedContract] = []
    public private(set) var hasLoaded = false
    public private(set) var errorMessage: String?
    public var query = ""

    let repository: SignedContractsRepository
    public init(repository: SignedContractsRepository) { self.repository = repository }

    /// The book as the search box leaves it.
    public var book: ContractBook { ContractBook(contracts.filter { $0.matches(query) }) }
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
        var saved = try await repository.save(contract)
        if let index = contracts.firstIndex(where: { $0.id == saved.id }) {
            // the saved row comes back without the file count it had
            saved.fileCount = saved.fileCount ?? contracts[index].fileCount
            contracts[index] = saved
        } else {
            saved.fileCount = saved.fileCount ?? 0
            contracts.append(saved)
        }
        return saved
    }

    @MainActor
    public func delete(_ contract: SignedContract) async throws {
        try await repository.delete(id: contract.id)
        contracts.removeAll { $0.id == contract.id }
    }

    @MainActor
    public func setFileCount(_ count: Int, for id: UUID) {
        guard let index = contracts.firstIndex(where: { $0.id == id }) else { return }
        contracts[index].fileCount = count
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

                    if model.contracts.count > 3 { searchField }

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
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.load() }
        }
        .task { await model.load() }
        .sheet(item: $creating) { draft in
            SignedContractForm(contract: draft, isNew: true) { try await model.save($0) }
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.Palette.textSecondary)
            TextField("Client, ville, PDL, fournisseur…", text: $model.query)
                .autocorrectionDisabled()
                .foregroundStyle(Theme.Palette.textPrimary)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Palette.textSecondary)
                }
                .accessibilityLabel("Effacer la recherche")
            }
        }
        .font(Theme.Typography.body)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            .fill(Theme.Palette.grouped))
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
            if book.isEmpty {
                Text("Aucun contrat ne correspond à « \(model.query) ».")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            section("Prochaines échéances", book.upcoming)
            section("Sans date d'échéance", book.undated)
            section("Échéance passée", book.expired)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ contracts: [SignedContract]) -> some View {
        if !contracts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("\(title) (\(contracts.count))")
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
        var parts: [String] = []
        let points = contract.filledPoints
        for energy in contract.energies {
            let count = points.filter { $0.energy == energy }.count
            parts.append(count > 1 ? "\(count) \(energy.pointName)" : energy.label)
        }
        if let supplier = contract.newSupplier?.nonBlank { parts.append(supplier) }
        if let city = contract.city?.nonBlank { parts.append(city) }
        if let files = contract.fileCount, files > 0 {
            parts.append(files == 1 ? "1 document" : "\(files) documents")
        }
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
    @State private var duplicating: SignedContract?
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

                        HStack(spacing: Theme.Spacing.m) {
                            SecondaryActionButton("Modifier", systemImage: "pencil") { editing = contract }
                            SecondaryActionButton("Dupliquer", systemImage: "plus.square.on.square") {
                                duplicating = contract.duplicate()
                            }
                        }

                        pointsCard(contract)

                        ContractFilesSection(contractID: contractID,
                                             repository: model.repository) { count in
                            model.setFileCount(count, for: contractID)
                        }

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
        .sheet(item: $duplicating) { draft in
            SignedContractForm(contract: draft, isNew: true) { try await model.save($0) }
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
            Text("Le contrat et ses documents disparaîtront définitivement.")
        }
    }

    @ViewBuilder
    private func pointsCard(_ contract: SignedContract) -> some View {
        let points = contract.filledPoints
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text(points.count > 1 ? "Points de livraison (\(points.count))" : "Point de livraison")
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            if points.isEmpty {
                Text("Aucun PDL/PRM ni PCE renseigné. Ajoutez-les avec « Modifier ».")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            ForEach(points) { point in
                HStack(alignment: .top, spacing: Theme.Spacing.m) {
                    Image(systemName: point.energy.icon)
                        .font(.system(size: 15))
                        .foregroundStyle(point.energy == .electricite ? Theme.Palette.rewardText
                                                                      : Theme.Palette.staleText)
                        .frame(width: 22)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(point.energy.pointName) · \(point.number)")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .textSelection(.enabled)
                        let details = [point.label?.nonBlank, point.site?.nonBlank].compactMap { $0 }
                        if !details.isEmpty {
                            Text(details.joined(separator: " · "))
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = point.number
                    } label: { Label("Copier le numéro", systemImage: "doc.on.doc") }
                }
            }
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
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

// MARK: - Files

@MainActor
@Observable
final class ContractFilesModel {
    private(set) var files: [ContractFile] = []
    private(set) var isUploading = false
    private(set) var hasLoaded = false
    var errorMessage: String?

    private let contractID: UUID
    private let repository: SignedContractsRepository
    private let onCount: (Int) -> Void

    init(contractID: UUID, repository: SignedContractsRepository, onCount: @escaping (Int) -> Void) {
        self.contractID = contractID
        self.repository = repository
        self.onCount = onCount
    }

    func load() async {
        do {
            files = try await repository.files(contractID: contractID)
            hasLoaded = true
            onCount(files.count)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func add(_ uploads: [DocumentUpload]) async {
        isUploading = true
        defer { isUploading = false }
        errorMessage = nil
        for upload in uploads {
            do {
                _ = try await repository.addFile(upload, to: contractID)
            } catch {
                errorMessage = "\(upload.filename) : \(error.localizedDescription)"
            }
        }
        await load()
    }

    func remove(_ file: ContractFile) async {
        do {
            try await repository.removeFile(file)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func localFile(for file: ContractFile) async -> URL? {
        do {
            let data = try await repository.data(of: file)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.filename)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

/// The contract's papers: scanned, picked from Photos or from Files, opened
/// in Quick Look (where they can be shared, printed or annotated).
struct ContractFilesSection: View {
    @State private var model: ContractFilesModel
    @State private var previewURL: URL?
    @State private var removing: ContractFile?

    init(contractID: UUID, repository: SignedContractsRepository, onCount: @escaping (Int) -> Void) {
        _model = State(wrappedValue: ContractFilesModel(contractID: contractID, repository: repository,
                                                        onCount: onCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                Text(model.files.isEmpty ? "Documents" : "Documents (\(model.files.count))")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                if model.isUploading { ProgressView().tint(Theme.Palette.brand) }
            }

            if model.hasLoaded && model.files.isEmpty {
                Text("Contrat signé, factures, pièce d'identité… en PDF ou en photo, autant que nécessaire.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.files) { file in
                HStack(spacing: Theme.Spacing.m) {
                    Button {
                        Task { previewURL = await model.localFile(for: file) }
                    } label: {
                        row(file)
                    }
                    .buttonStyle(.plain)
                    Menu {
                        Button {
                            Task { previewURL = await model.localFile(for: file) }
                        } label: { Label("Ouvrir", systemImage: "eye") }
                        Button(role: .destructive) { removing = file } label: {
                            Label("Retirer", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .frame(width: 36, height: 38)
                    }
                    .accessibilityLabel("Options pour \(file.filename)")
                }
            }

            if let message = model.errorMessage {
                Text(message)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AddDocumentButton(title: "Ajouter des documents",
                              scanTitle: "Scanner un document",
                              scanName: "Document scanné",
                              onPicked: { uploads in Task { await model.add(uploads) } },
                              onError: { model.errorMessage = $0 })
                .disabled(model.isUploading)
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .quickLookPreview($previewURL)
        .confirmationDialog("Retirer ce document ?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("Retirer", role: .destructive) {
                if let file = removing { Task { await model.remove(file) } }
                removing = nil
            }
            Button("Annuler", role: .cancel) { removing = nil }
        } message: {
            Text(removing?.filename ?? "")
        }
        .task { await model.load() }
    }

    private func row(_ file: ContractFile) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: file.isPDF ? "doc.richtext" : "photo")
                .font(.system(size: 18))
                .foregroundStyle(Theme.Palette.brand)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.Palette.brandSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text([ContractDay.long(file.createdAt), file.sizeLabel].compactMap { $0 }
                        .joined(separator: " · "))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - The form

struct SignedContractForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SignedContract
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pastesList = false

    private let isNew: Bool
    private let save: (SignedContract) async throws -> SignedContract

    init(contract: SignedContract, isNew: Bool,
         save: @escaping (SignedContract) async throws -> SignedContract) {
        var contract = contract
        // a new contract opens on one empty meter, ready to type in
        if contract.deliveryPoints.isEmpty { contract.deliveryPoints = [DeliveryPoint()] }
        _draft = State(initialValue: contract)
        self.isNew = isNew
        self.save = save
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    clientSection
                    pointsSection
                    contractSection
                    previousSection

                    group("Notes")
                    LabelledField("Notes (facultatif)") {
                        TextField("Conditions, rappel prévu…", text: text(\.notes), axis: .vertical)
                            .lineLimit(3...10)
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { Task { await submit() } }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $pastesList) {
                PastePointsSheet { points in
                    draft.deliveryPoints.removeAll { $0.number.nonBlank == nil && $0.label?.nonBlank == nil
                                                     && $0.site?.nonBlank == nil }
                    draft.deliveryPoints += points
                }
            }
        }
    }

    // MARK: sections

    @ViewBuilder
    private var clientSection: some View {
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
    }

    @ViewBuilder
    private var pointsSection: some View {
        group("Points de livraison (PDL/PRM et PCE)")
        Text("Autant que le client en a : un par compteur, électricité ou gaz.")
            .font(Theme.Typography.secondary)
            .foregroundStyle(Theme.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        ForEach($draft.deliveryPoints) { $point in
            DeliveryPointEditor(point: $point,
                                index: (draft.deliveryPoints.firstIndex { $0.id == point.id } ?? 0) + 1) {
                draft.deliveryPoints.removeAll { $0.id == point.id }
            }
        }

        HStack(spacing: Theme.Spacing.m) {
            SecondaryActionButton("Ajouter", systemImage: "plus") {
                // the next meter is usually of the same energy as the last
                draft.deliveryPoints.append(DeliveryPoint(energy: draft.deliveryPoints.last?.energy ?? .electricite))
            }
            SecondaryActionButton("Coller une liste", systemImage: "list.bullet.clipboard") {
                pastesList = true
            }
        }
    }

    @ViewBuilder
    private var contractSection: some View {
        group("Contrat signé")
        LabelledField("Nouveau fournisseur") {
            TextField("Fournisseur choisi", text: text(\.newSupplier))
        }
        DayField("Date de signature", day: $draft.signedOn)
        DayField("Début du contrat", day: $draft.startsOn)
        DayField("Échéance du contrat", day: $draft.endsOn)
    }

    @ViewBuilder
    private var previousSection: some View {
        group("Ancien contrat (pour la lettre de résiliation)")
        LabelledField("Ancien fournisseur") {
            TextField("EDF, Engie…", text: text(\.previousSupplier))
        }
        LabelledField("Adresse de résiliation du fournisseur") {
            TextField("Service, adresse, code postal et ville",
                      text: text(\.previousSupplierAddress), axis: .vertical)
                .lineLimit(2...6)
        }
        LabelledField("N° client ou de contrat") {
            TextField("Sur la facture de l'ancien fournisseur", text: text(\.previousReference))
                .autocorrectionDisabled()
        }
        DayField("Résiliation à compter du", day: $draft.terminationOn)
    }

    // MARK: rules

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
        guard canSave else { return }
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

/// One meter in the form.
struct DeliveryPointEditor: View {
    @Binding var point: DeliveryPoint
    let index: Int
    let onRemove: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                Picker("Énergie", selection: $point.energy) {
                    ForEach(EnergyKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                        .foregroundStyle(Theme.Palette.destructive)
                        .frame(width: 40, height: 34)
                }
                .accessibilityLabel("Retirer le point \(index)")
            }
            LabelledField("\(point.energy.pointName) n° \(index)") {
                TextField(point.energy == .electricite ? "14 chiffres" : "GI… ou 14 chiffres",
                          text: $point.number)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            if showsDetails || point.label?.nonBlank != nil || point.site?.nonBlank != nil {
                LabelledField("Nom du site (facultatif)") {
                    TextField("Siège, entrepôt, boutique…", text: Binding(
                        get: { point.label ?? "" }, set: { point.label = $0 }))
                }
                LabelledField("Adresse du site (si différente)") {
                    TextField("Adresse du compteur", text: Binding(
                        get: { point.site ?? "" }, set: { point.site = $0 }))
                }
            } else {
                Button { showsDetails = true } label: {
                    Label("Nom ou adresse du site", systemImage: "plus.circle")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.brand)
                }
            }
        }
        .padding(Theme.Spacing.l)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous)
            .fill(Theme.Palette.grouped))
    }
}

/// Many meters at once: pasted from a spreadsheet, an email or the
/// supplier's list.
struct PastePointsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var energy: EnergyKind = .electricite
    let onAdd: ([DeliveryPoint]) -> Void

    private var points: [DeliveryPoint] { DeliveryPoint.parse(text, energy: energy) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text("Collez les numéros, un par ligne (ou séparés par des virgules).")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Picker("Énergie", selection: $energy) {
                        ForEach(EnergyKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabelledField("Numéros") {
                        TextField("14523698741230\n14523698741231", text: $text, axis: .vertical)
                            .lineLimit(6...16)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                    }
                    PrimaryActionButton(points.isEmpty ? "Ajouter"
                                        : "Ajouter \(points.count) \(energy.pointName)") {
                        onAdd(points)
                        dismiss()
                    }
                    .disabled(points.isEmpty)
                    .opacity(points.isEmpty ? 0.5 : 1)
                }
                .padding(Theme.Spacing.gutter)
            }
            .background(BrandBackground())
            .navigationTitle("Coller une liste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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
