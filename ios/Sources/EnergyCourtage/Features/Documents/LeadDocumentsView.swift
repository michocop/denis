import SwiftUI
import Observation
import PhotosUI
import UniformTypeIdentifiers
import QuickLook
#if canImport(VisionKit)
import VisionKit
#endif

// MARK: - Turning what the person picked into an upload

enum DocumentSources {
    /// Photos are shrunk to at most 2400 px on their long side and saved as
    /// JPEG: a bill photographed on a recent iPhone is 5-10 MB as it comes,
    /// and still perfectly legible at a quarter of that.
    static func upload(fromImageData data: Data, name: String) -> DocumentUpload? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 2400 / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        return DocumentUpload(data: jpeg, filename: "\(name).jpg", mimeType: "image/jpeg")
        #else
        return nil
        #endif
    }

    static func upload(fromFile url: URL) throws -> DocumentUpload {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true {
            return DocumentUpload(data: data, filename: url.lastPathComponent,
                                  mimeType: "application/pdf")
        }
        if type?.conforms(to: .image) == true,
           let photo = upload(fromImageData: data, name: url.deletingPathExtension().lastPathComponent) {
            return photo
        }
        throw DocumentError.unsupported
    }

    /// Scanned pages, one A4 page each, as a single PDF: what an accountant
    /// expects to receive, rather than a handful of loose photos.
    static func upload(fromScannedPages pages: [Any]) -> DocumentUpload? {
        #if canImport(UIKit)
        let images = pages.compactMap { $0 as? UIImage }
        guard !images.isEmpty else { return nil }
        let a4 = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let data = UIGraphicsPDFRenderer(bounds: a4).pdfData { context in
            for image in images {
                context.beginPage()
                let scale = min(a4.width / image.size.width, a4.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: (a4.width - size.width) / 2, y: (a4.height - size.height) / 2,
                                      width: size.width, height: size.height))
            }
        }
        let stamp = Date.now.formatted(.dateTime.day().month().year())
        return DocumentUpload(data: data, filename: "Facture scannée \(stamp).pdf",
                              mimeType: "application/pdf")
        #else
        return nil
        #endif
    }
}

#if canImport(VisionKit) && canImport(UIKit)
/// The system document scanner: edge detection, perspective correction and
/// contrast, which is what makes a photographed bill readable.
struct DocumentScanner: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void
    let onCancel: () -> Void

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            parent.onFinish((0..<scan.pageCount).map(scan.imageOfPage(at:)))
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}
#endif

// MARK: - The "Ajouter" menu

/// Scan, photo or file: the three ways a bill reaches a phone. Calls back
/// with uploads ready to send.
struct AddDocumentButton: View {
    var title = "Ajouter un document"
    let onPicked: ([DocumentUpload]) -> Void
    let onError: (String) -> Void

    @State private var showsScanner = false
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            #if canImport(VisionKit) && canImport(UIKit)
            if DocumentScanner.isAvailable {
                Button { showsScanner = true } label: {
                    Label("Scanner une facture", systemImage: "doc.viewfinder")
                }
            }
            #endif
            Button { showsPhotos = true } label: {
                Label("Choisir des photos", systemImage: "photo.on.rectangle")
            }
            Button { showsFiles = true } label: {
                Label("Choisir un fichier", systemImage: "folder")
            }
        } label: {
            Label(title, systemImage: "paperclip")
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .brandGlass(in: Capsule(), interactive: true)
        }
        .photosPicker(isPresented: $showsPhotos, selection: $photoItems,
                      maxSelectionCount: 5, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var uploads: [DocumentUpload] = []
                for (index, item) in items.enumerated() {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let upload = DocumentSources.upload(fromImageData: data,
                                                           name: "Photo \(index + 1)") {
                        uploads.append(upload)
                    }
                }
                photoItems = []
                uploads.isEmpty ? onError("Ces photos n'ont pas pu être lues.") : onPicked(uploads)
            }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.pdf, .image],
                      allowsMultipleSelection: true) { result in
            do {
                onPicked(try result.get().map(DocumentSources.upload(fromFile:)))
            } catch {
                onError(error.localizedDescription)
            }
        }
        #if canImport(VisionKit) && canImport(UIKit)
        .fullScreenCover(isPresented: $showsScanner) {
            DocumentScanner(onFinish: { pages in
                showsScanner = false
                if let upload = DocumentSources.upload(fromScannedPages: pages) { onPicked([upload]) }
            }, onCancel: { showsScanner = false })
            .ignoresSafeArea()
        }
        #endif
    }
}

// MARK: - A lead's documents

@MainActor
@Observable
final class LeadDocumentsModel {
    private(set) var documents: [LeadDocument] = []
    private(set) var isUploading = false
    var errorMessage: String?

    private let recommendationID: UUID
    private let repository: DocumentsRepository

    init(recommendationID: UUID, repository: DocumentsRepository) {
        self.recommendationID = recommendationID
        self.repository = repository
    }

    func load() async {
        do {
            documents = try await repository.documents(recommendationID: recommendationID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func add(_ uploads: [DocumentUpload]) async {
        isUploading = true
        defer { isUploading = false }
        for upload in uploads {
            do {
                _ = try await repository.add(upload, to: recommendationID)
            } catch {
                errorMessage = "\(upload.filename) : \(error.localizedDescription)"
            }
        }
        await load()
    }

    func remove(_ document: LeadDocument) async {
        do {
            try await repository.remove(document)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Written to a temporary file named after the document, for Quick Look
    /// and the share sheet.
    func localFile(for document: LeadDocument) async -> URL? {
        do {
            let data = try await repository.data(of: document)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(document.filename)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

/// The documents section of a recommendation's detail.
struct LeadDocumentsSection: View {
    @State private var model: LeadDocumentsModel
    @State private var previewURL: URL?

    init(recommendationID: UUID, repository: DocumentsRepository) {
        _model = State(wrappedValue: LeadDocumentsModel(recommendationID: recommendationID,
                                                         repository: repository))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                Text("Documents")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                if model.isUploading { ProgressView().tint(Theme.Palette.brand) }
            }

            if model.documents.isEmpty {
                Text("Ajoutez la facture d'énergie du filleul : c'est elle qui permet de comparer les offres.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.documents) { document in
                Button {
                    Task { previewURL = await model.localFile(for: document) }
                } label: {
                    row(document)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        Task { await model.remove(document) }
                    } label: {
                        Label("Retirer", systemImage: "trash")
                    }
                }
            }

            if let message = model.errorMessage {
                Text(message)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AddDocumentButton(
                onPicked: { uploads in Task { await model.add(uploads) } },
                onError: { model.errorMessage = $0 })
                .disabled(model.isUploading)
        }
        .padding(Theme.Spacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .quickLookPreview($previewURL)
        .task { await model.load() }
    }

    private func row(_ document: LeadDocument) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: document.isPDF ? "doc.richtext" : "photo")
                .font(.system(size: 18))
                .foregroundStyle(Theme.Palette.brand)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.Palette.brandSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text(document.filename)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text([document.kindLabel, document.sizeLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Ouvrir le document")
    }
}
