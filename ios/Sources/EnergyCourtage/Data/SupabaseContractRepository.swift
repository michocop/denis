import Foundation

/// The apporteur's contract: signed through sign_apporteur_contract, read
/// from apporteur_contracts (RLS: the apporteur's own, or any for an admin),
/// and its PDF from the private "contracts" bucket once the server filed it.
public struct SupabaseContractRepository: ContractRepository {
    private let client: SupabaseClient
    private static let bucket = "contracts"

    public init(client: SupabaseClient) { self.client = client }

    public func contract(for profileID: UUID) async throws -> ApporteurContract? {
        let rows: [ApporteurContract] = try await client.get("apporteur_contracts", query: [
            URLQueryItem(name: "profile_id", value: "eq.\(profileID.uuidString)"),
            URLQueryItem(name: "order", value: "signed_at.desc"),
            URLQueryItem(name: "limit", value: "1"),
        ])
        return rows.first
    }

    public func sign(status: BusinessStatus, contractSHA256: String,
                     mandateSHA256: String) async throws -> ApporteurContract {
        try await client.rpc("sign_apporteur_contract", body: [
            "p_business_status": AnyEncodable(status.rawValue),
            "p_contract_sha256": AnyEncodable(contractSHA256),
            "p_mandate_sha256": AnyEncodable(mandateSHA256),
        ])
    }

    public func pdf(of contract: ApporteurContract) async throws -> Data? {
        var path = contract.pdfPath
        if path == nil {
            // filed a moment after the signature: ask again for the row
            let rows: [ApporteurContract] = try await client.get("apporteur_contracts", query: [
                URLQueryItem(name: "id", value: "eq.\(contract.id.uuidString)"),
                URLQueryItem(name: "limit", value: "1"),
            ])
            path = rows.first?.pdfPath
        }
        guard let path else { return nil }
        return try await client.download(bucket: Self.bucket, path: path)
    }
}
