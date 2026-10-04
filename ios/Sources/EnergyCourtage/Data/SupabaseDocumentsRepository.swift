import Foundation

/// Lead documents: bytes in the private `documents` bucket, listed in the
/// `documents` table. Uploading is two steps -- the file, then
/// `register_document`, which checks the file is really there, under this
/// lead, of an accepted type and size -- so a row never points at nothing.
public struct SupabaseDocumentsRepository: DocumentsRepository {
    private let client: SupabaseClient
    private static let bucket = "documents"

    public init(client: SupabaseClient) { self.client = client }

    public func documents(recommendationID: UUID) async throws -> [LeadDocument] {
        try await client.get("documents", query: [
            URLQueryItem(name: "recommendation_id", value: "eq.\(recommendationID.uuidString)"),
            URLQueryItem(name: "order", value: "created_at.desc")
        ])
    }

    public func add(_ upload: DocumentUpload, to recommendationID: UUID) async throws -> LeadDocument {
        guard upload.data.count <= DocumentUpload.maxBytes else { throw DocumentError.tooLarge }
        guard ["application/pdf", "image/jpeg", "image/png", "image/heic"].contains(upload.mimeType) else {
            throw DocumentError.unsupported
        }
        let path = "\(recommendationID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).\(upload.fileExtension)"
        try await client.upload(bucket: Self.bucket, path: path, data: upload.data,
                                contentType: upload.mimeType)
        return try await client.rpc("register_document", body: [
            "p_recommendation_id": AnyEncodable(recommendationID.uuidString),
            "p_path": AnyEncodable(path),
            "p_filename": AnyEncodable(upload.filename),
            "p_byte_size": AnyEncodable(upload.data.count),
            "p_mime_type": AnyEncodable(upload.mimeType),
            "p_kind": AnyEncodable(upload.kind)
        ])
    }

    public func data(of document: LeadDocument) async throws -> Data {
        try await client.download(bucket: Self.bucket, path: document.storagePath)
    }

    /// The row first, so the list never shows a file that is gone; the bytes
    /// after. A failure in between leaves an unlisted file, not a broken row.
    public func remove(_ document: LeadDocument) async throws {
        let path: String = try await client.rpc("remove_document", body: [
            "p_document_id": AnyEncodable(document.id.uuidString)
        ])
        try? await client.removeObject(bucket: Self.bucket, path: path)
    }
}
