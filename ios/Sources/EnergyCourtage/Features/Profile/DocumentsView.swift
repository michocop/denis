import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Observation

@Observable
public final class DocumentsViewModel {
    public private(set) var items: [DocumentItem] = []
    public private(set) var justificatifs: [JustificatifKind: Justificatif] = [:]
    public private(set) var isLoading = true
    public private(set) var uploading: JustificatifKind?
    public var errorMessage: String?
    public var filters = DocumentFilters()

    private let repository: DocumentsRepository
    public init(repository: DocumentsRepository) { self.repository = repository }

    public var visibleItems: [DocumentItem] { filters.apply(to: items) }

    @MainActor
    public func load() async {
        do {
            items = try await repository.documents()
            let files = try await repository.justificatifs()
            justificatifs = Dictionary(files.map { ($0.kind, $0) }, uniquingKeysWith: { a, _ in a })
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 10 MB, the same ceiling the server applies.
    public static let maxBytes = 10 * 1024 * 1024

    @MainActor
    public func upload(_ kind: JustificatifKind, data: Data, filename: String,
                       contentType: String) async {
        guard data.count <= Self.maxBytes else {
            errorMessage = "Fichier trop lourd (10 Mo maximum)."
            return
        }
        uploading = kind
        defer { uploading = nil }
        do {
            try await repository.upload(kind, data: data, filename: filename,
                                        contentType: contentType)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// "Mes documents": the reconnaissances d'honoraires under "Fichiers", and the
/// identity card and RIB under "Mes justificatifs", deleted after 30 days.
public struct DocumentsView: View {
    @State private var model: DocumentsViewModel
    @State private var openedInvoice: DocumentItem?
    @State private var pickingFor: JustificatifKind?
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var photo: PhotosPickerItem?

    private let invoices: InvoiceRepository
    private let signerName: String
    private let isAdmin: Bool

    public init(model: DocumentsViewModel, invoices: InvoiceRepository,
                signerName: String, isAdmin: Bool) {
        _model = State(wrappedValue: model)
        self.invoices = invoices
        self.signerName = signerName
        self.isAdmin = isAdmin
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                SearchField("Rechercher un document...", text: $model.filters.query)
                filterChips

                Text("Fichiers")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.top, Theme.Spacing.s)

                if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if model.visibleItems.isEmpty {
                    Text("Aucun document")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    ForEach(model.visibleItems) { item in
                        Button { openedInvoice = item } label: { fileRow(item) }
                            .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Mes justificatifs")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Supprimés après 30 jours")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.top, Theme.Spacing.l)

                ForEach(JustificatifKind.allCases) { kind in
                    justificatifRow(kind)
                }

                if let message = model.errorMessage {
                    Text(message)
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.destructive)
                }
            }
            .padding(Theme.Spacing.gutter)
        }
        .background(Theme.Palette.canvas.ignoresSafeArea())
        .navigationTitle("Mes documents")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $openedInvoice, onDismiss: { Task { await model.load() } }) { item in
            InvoiceView(model: InvoiceViewModel(invoiceID: item.invoiceId, repository: invoices),
                        signerName: signerName, isAdmin: isAdmin)
        }
        .photosPicker(isPresented: $showsPhotos, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item, let kind = pickingFor else { return }
            photo = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await model.upload(kind, data: data, filename: "\(kind.rawValue).jpg",
                                       contentType: "image/jpeg")
                }
            }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.pdf, .image]) { result in
            guard let kind = pickingFor, case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.errorMessage = "Le fichier n'a pas pu être lu."
                return
            }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            Task { await model.upload(kind, data: data, filename: url.lastPathComponent,
                                      contentType: type) }
        }
    }

    // MARK: Filters

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                Menu {
                    Picker("Période", selection: $model.filters.period) {
                        ForEach(DocumentPeriod.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    chip("Période", icon: "calendar", active: model.filters.period != .all)
                }
                Menu {
                    Picker("Étiquettes", selection: $model.filters.tag) {
                        Text("Toutes").tag(DocumentTag?.none)
                        ForEach(DocumentTag.allCases) { Text($0.label).tag(DocumentTag?.some($0)) }
                    }
                } label: {
                    chip("Étiquettes", icon: "tag", active: model.filters.tag != nil)
                }
                Menu {
                    Picker("Actifs", selection: $model.filters.active) {
                        Text("Tous").tag(Bool?.none)
                        Text("Actifs").tag(Bool?.some(true))
                        Text("Archivés").tag(Bool?.some(false))
                    }
                } label: {
                    chip(model.filters.active == false ? "Archivés" : "Actifs",
                         icon: "archivebox", active: model.filters.active != nil)
                }
                Menu {
                    Picker("Types", selection: $model.filters.kind) {
                        Text("Tous les types").tag(String?.none)
                        Text("Reconnaissances d'honoraires").tag(String?.some("honoraires"))
                        Text("Avoirs").tag(String?.some("avoir"))
                    }
                } label: {
                    chip(model.filters.kind == "avoir" ? "Avoirs"
                         : model.filters.kind == "honoraires" ? "Honoraires" : "Tous les types",
                         icon: "doc.text", active: model.filters.kind != nil)
                }
            }
        }
    }

    private func chip(_ title: String, icon: String, active: Bool) -> some View {
        Label(title, systemImage: icon)
            .font(Theme.Typography.label)
            .foregroundStyle(active ? Theme.Palette.brand : Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Theme.Palette.brandSoft : Theme.Palette.track.opacity(0.6))
            )
    }

    // MARK: Rows

    private func fileRow(_ item: DocumentItem) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: item.kind == "avoir" ? "arrow.uturn.backward.circle" : "doc.text")
                .font(.system(size: 18))
                .foregroundStyle(Theme.Palette.brand)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.Palette.brandSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("\(item.number) · \(item.filleulName) · \(item.issuedAt.formatted(date: .numeric, time: .omitted))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(item.tag.label)
                .font(Theme.Typography.caption)
                .foregroundStyle(item.tag == .toSign ? Theme.Palette.rewardText : Theme.Palette.successText)
                .padding(.horizontal, Theme.Spacing.s)
                .padding(.vertical, 3)
                .background(Capsule().fill(item.tag == .toSign ? Theme.Palette.rewardSoft
                                                               : Theme.Palette.successSoft))
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
    }

    private func justificatifRow(_ kind: JustificatifKind) -> some View {
        let file = model.justificatifs[kind]
        return HStack(spacing: Theme.Spacing.m) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(Theme.Palette.brand)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.Palette.track))
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let file {
                    Text("Envoyé le \(file.uploadedAt.formatted(date: .numeric, time: .omitted)) · supprimé le \(file.expiresAt.formatted(date: .numeric, time: .omitted))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.successText)
                }
            }
            Spacer(minLength: 0)
            if model.uploading == kind {
                ProgressView()
            } else {
                Menu {
                    Button("Choisir une photo", systemImage: "photo") {
                        pickingFor = kind; showsPhotos = true
                    }
                    Button("Choisir un fichier (PDF)", systemImage: "folder") {
                        pickingFor = kind; showsFiles = true
                    }
                } label: {
                    Image(systemName: file == nil ? "icloud.and.arrow.up" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(file == nil ? "Envoyer \(kind.title)" : "Remplacer \(kind.title)")
            }
        }
    }
}
