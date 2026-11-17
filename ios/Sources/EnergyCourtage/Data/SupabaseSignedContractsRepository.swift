import Foundation

/// The owner's book, `signed_contracts`. RLS lets nobody but the members of
/// `contract_book_members` read or write a row, so an account without the
/// book gets an empty list and refused writes, whatever the app shows.
public struct SupabaseSignedContractsRepository: SignedContractsRepository {
    private let client: SupabaseClient
    private static let table = "signed_contracts"

    public init(client: SupabaseClient) { self.client = client }

    public func hasAccess() async throws -> Bool {
        try await client.rpc("has_contract_book")
    }

    public func contracts() async throws -> [SignedContract] {
        try await client.get(Self.table, query: [
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

    public func delete(id: UUID) async throws {
        try await client.delete(Self.table, match: [
            URLQueryItem(name: "id", value: "eq.\(id.uuidString)"),
        ])
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
            "site_address": text(c.siteAddress),
            "energy": AnyEncodable(c.energy.rawValue),
            "delivery_point": text(c.deliveryPoint),
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
