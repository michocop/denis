import Foundation

public struct SupabaseDocumentsRepository: DocumentsRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    private static let bucket = "justificatifs"

    public func documents() async throws -> [DocumentItem] {
        try await client.rpc("my_documents", body: [:])
    }

    public func justificatifs() async throws -> [Justificatif] {
        try await client.get("my_justificatifs", query: [
            URLQueryItem(name: "select", value: "id,kind,filename,uploaded_at,expires_at")
        ])
    }

    /// The file goes into the person's own folder first, then is recorded:
    /// the storage policy refuses any other folder, and the record refuses a
    /// path outside it, so neither step can be pointed at someone else.
    public func upload(_ kind: JustificatifKind, data: Data, filename: String,
                       contentType: String) async throws {
        let owner = try await client.currentUserID().uuidString.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        let path = "\(owner)/\(kind.rawValue)-\(UUID().uuidString.lowercased())"
            + (ext.isEmpty ? "" : ".\(ext)")
        try await client.upload(bucket: Self.bucket, path: path, data: data,
                                contentType: contentType)
        try await client.rpcVoid("record_justificatif", body: [
            "p_kind": AnyEncodable(kind.rawValue),
            "p_path": AnyEncodable(path),
            "p_filename": AnyEncodable(filename),
            "p_byte_size": AnyEncodable(data.count)
        ])
    }

    public func contactName() async throws -> String? {
        try await client.rpc("my_contact_name", body: [:])
    }
}

/// Demo documents that remember an upload for as long as the app runs.
actor DemoDocumentsStore {
    static let shared = DemoDocumentsStore()
    private(set) var uploaded: [JustificatifKind: Justificatif] = [:]

    func record(_ kind: JustificatifKind, filename: String) {
        uploaded[kind] = Justificatif(id: UUID(), kind: kind, filename: filename,
                                      uploadedAt: .now,
                                      expiresAt: .now.addingTimeInterval(30 * 86_400))
    }
}

public struct PreviewDocumentsRepository: DocumentsRepository {
    public init() {}

    public func documents() async throws -> [DocumentItem] {
        [
            DocumentItem(invoiceId: UUID(), number: "FA-2026-0001", kind: "honoraires",
                         status: "awaiting_signatures", amountTtc: 1300,
                         issuedAt: .now.addingTimeInterval(-8 * 86_400),
                         filleulName: "Thomas Dubois", apporteurName: "Johann Lefeuvre",
                         recommendationActive: true, hasPdf: false),
            DocumentItem(invoiceId: UUID(), number: "FA-2026-0002", kind: "honoraires",
                         status: "paid", amountTtc: 300,
                         issuedAt: .now.addingTimeInterval(-60 * 86_400),
                         filleulName: "Claire Moreau", apporteurName: "Johann Lefeuvre",
                         recommendationActive: false, hasPdf: true)
        ]
    }

    public func justificatifs() async throws -> [Justificatif] {
        Array(await DemoDocumentsStore.shared.uploaded.values)
    }

    public func upload(_ kind: JustificatifKind, data: Data, filename: String,
                       contentType: String) async throws {
        await DemoDocumentsStore.shared.record(kind, filename: filename)
    }

    public func contactName() async throws -> String? { "Pierre-Louis Tettamanti" }
}
