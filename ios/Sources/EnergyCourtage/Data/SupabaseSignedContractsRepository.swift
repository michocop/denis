import Foundation

/// The owner's book, `signed_contracts`. RLS lets nobody but the members of
/// `contract_book_members` read or write a row, so an account without the
/// book gets an empty list and refused writes, whatever the app shows.
public struct SupabaseSignedContractsRepository: SignedContractsRepository {
    private let client: SupabaseClient
    private static let table = "signed_contracts"
    private static let filesTable = "signed_contract_files"
    private static let bucket = "contract-book"

    public init(client: SupabaseClient) { self.client = client }

    public func hasAccess() async throws -> Bool {
        try await client.rpc("has_contract_book")
    }

    public func contracts() async throws -> [SignedContract] {
        try await client.get(Self.table, query: [
            URLQueryItem(name: "select", value: "*,signed_contract_files(count)"),
            URLQueryItem(name: "order", value: "ends_on.asc.nullslast,client_name.asc"),
        ])
    }

    public func save(_ contract: SignedContract) async throws -> SignedContract {
        let rows: [SignedContract] = try await client.upsert(
            Self.table, values: Self.values(of: contract), onConflict: "id")
        guard let saved = rows.first else {
            throw SupabaseError.http(status: 403, message: "")
        }
        return saved
    }

    /// The files' bytes first (best effort), then the row, which takes the
    /// file rows with it.
    public func delete(id: UUID) async throws {
        for file in (try? await files(contractID: id)) ?? [] {
            try? await client.removeObject(bucket: Self.bucket, path: file.storagePath)
        }
        try await client.delete(Self.table, match: [
            URLQueryItem(name: "id", value: "eq.\(id.uuidString)"),
        ])
    }

    public func files(contractID: UUID) async throws -> [ContractFile] {
        try await client.get(Self.filesTable, query: [
            URLQueryItem(name: "contract_id", value: "eq.\(contractID.uuidString)"),
            URLQueryItem(name: "order", value: "created_at.asc"),
        ])
    }

    /// The bytes, then the row that lists them: a failure in between leaves
    /// an unlisted file, never a row pointing at nothing.
    public func addFile(_ upload: DocumentUpload, to contractID: UUID) async throws -> ContractFile {
        guard upload.data.count <= DocumentUpload.maxBytes else { throw DocumentError.tooLarge }
        guard ["application/pdf", "image/jpeg", "image/png", "image/heic"].contains(upload.mimeType) else {
            throw DocumentError.unsupported
        }
        let path = "\(contractID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).\(upload.fileExtension)"
        try await client.upload(bucket: Self.bucket, path: path, data: upload.data,
                                contentType: upload.mimeType)
        let rows: [ContractFile] = try await client.insert(Self.filesTable, values: [
            "contract_id": AnyEncodable(contractID),
            "storage_path": AnyEncodable(path),
            "filename": AnyEncodable(String(upload.filename.prefix(255))),
            "byte_size": AnyEncodable(upload.data.count),
            "mime_type": AnyEncodable(upload.mimeType),
        ])
        guard let file = rows.first else { throw SupabaseError.http(status: 403, message: "") }
        return file
    }

    public func data(of file: ContractFile) async throws -> Data {
        try await client.download(bucket: Self.bucket, path: file.storagePath)
    }

    /// The row first, so the list never shows a file that is gone.
    public func removeFile(_ file: ContractFile) async throws {
        try await client.delete(Self.filesTable, match: [
            URLQueryItem(name: "id", value: "eq.\(file.id.uuidString)"),
        ])
        try? await client.removeObject(bucket: Self.bucket, path: file.storagePath)
    }

    /// Every column, blanks as null: emptying a field in the form has to
    /// clear it on the server, not leave the old value.
    static func values(of c: SignedContract) -> [String: AnyEncodable] {
        func text(_ value: String?) -> AnyEncodable { AnyEncodable(value?.nonBlank) }
        return [
            "id": AnyEncodable(c.id),
            "client_kind": AnyEncodable(c.clientKind.rawValue),
            "client_name": AnyEncodable(c.clientName.trimmingCharacters(in: .whitespacesAndNewlines)),
            "signatory_name": text(c.signatoryName),
            "signatory_title": text(c.signatoryTitle),
            "siret": text(c.siret.map { $0.filter { !$0.isWhitespace } }),
            "phone": text(c.phone),
            "email": text(c.email),
            "address": text(c.address),
            "postal_code": text(c.postalCode),
            "city": text(c.city),
            "delivery_points": AnyEncodable(c.filledPoints.map { point in
                DeliveryPoint(id: point.id, energy: point.energy,
                              number: point.number.trimmingCharacters(in: .whitespacesAndNewlines),
                              label: point.label?.nonBlank, site: point.site?.nonBlank)
            }),
            "previous_supplier": text(c.previousSupplier),
            "previous_supplier_address": text(c.previousSupplierAddress),
            "previous_reference": text(c.previousReference),
            "termination_on": text(c.terminationOn),
            "new_supplier": text(c.newSupplier),
            "signed_on": text(c.signedOn),
            "starts_on": text(c.startsOn),
            "ends_on": text(c.endsOn),
            "notes": text(c.notes),
        ]
    }
}
