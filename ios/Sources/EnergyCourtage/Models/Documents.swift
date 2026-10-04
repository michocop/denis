import Foundation

/// A file attached to a recommendation: the filleul's energy bill, or a
/// quote, contract or invoice the company attached.
public struct LeadDocument: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var recommendationId: UUID
    public var kind: String
    public var storagePath: String
    public var filename: String
    public var byteSize: Int64?
    public var mimeType: String?
    public var uploadedBy: UUID
    public var createdAt: Date

    public init(id: UUID, recommendationId: UUID, kind: String, storagePath: String,
                filename: String, byteSize: Int64?, mimeType: String?,
                uploadedBy: UUID, createdAt: Date) {
        self.id = id; self.recommendationId = recommendationId; self.kind = kind
        self.storagePath = storagePath; self.filename = filename; self.byteSize = byteSize
        self.mimeType = mimeType; self.uploadedBy = uploadedBy; self.createdAt = createdAt
    }

    public var kindLabel: String {
        switch kind {
        case "energy_bill": return "Facture d'énergie"
        case "quote":       return "Devis"
        case "contract":    return "Contrat"
        case "invoice":     return "Facture"
        default:            return "Document"
        }
    }

    public var isPDF: Bool { mimeType == "application/pdf" || filename.lowercased().hasSuffix(".pdf") }

    public var sizeLabel: String? {
        byteSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

/// A file ready to send: bytes, the name shown, and what it is.
public struct DocumentUpload: Sendable, Hashable {
    public var data: Data
    public var filename: String
    public var mimeType: String
    public var kind: String

    /// The server's own limit, checked before anything is sent.
    public static let maxBytes = 10 * 1024 * 1024

    public init(data: Data, filename: String, mimeType: String, kind: String = "energy_bill") {
        self.data = data; self.filename = filename; self.mimeType = mimeType; self.kind = kind
    }

    var fileExtension: String {
        switch mimeType {
        case "application/pdf": return "pdf"
        case "image/png":       return "png"
        case "image/heic":      return "heic"
        default:                return "jpg"
        }
    }
}

public protocol DocumentsRepository: Sendable {
    func documents(recommendationID: UUID) async throws -> [LeadDocument]
    func add(_ upload: DocumentUpload, to recommendationID: UUID) async throws -> LeadDocument
    func data(of document: LeadDocument) async throws -> Data
    func remove(_ document: LeadDocument) async throws
}

public enum DocumentError: LocalizedError, Equatable {
    case tooLarge
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .tooLarge:    return "Ce fichier dépasse 10 Mo."
        case .unsupported: return "Seuls les PDF et les photos sont acceptés."
        }
    }
}

/// Documents for the demo: kept in memory for as long as the app runs.
public actor PreviewDocumentsRepository: DocumentsRepository {
    private var files: [UUID: (LeadDocument, Data)] = [:]

    public init() {}

    public func documents(recommendationID: UUID) async throws -> [LeadDocument] {
        files.values.map(\.0).filter { $0.recommendationId == recommendationID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func add(_ upload: DocumentUpload, to recommendationID: UUID) async throws -> LeadDocument {
        guard upload.data.count <= DocumentUpload.maxBytes else { throw DocumentError.tooLarge }
        let doc = LeadDocument(id: UUID(), recommendationId: recommendationID, kind: upload.kind,
                               storagePath: "\(recommendationID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).\(upload.fileExtension)",
                               filename: upload.filename, byteSize: Int64(upload.data.count),
                               mimeType: upload.mimeType, uploadedBy: UUID(), createdAt: .now)
        files[doc.id] = (doc, upload.data)
        return doc
    }

    public func data(of document: LeadDocument) async throws -> Data {
        files[document.id]?.1 ?? Data()
    }

    public func remove(_ document: LeadDocument) async throws {
        files[document.id] = nil
    }
}
