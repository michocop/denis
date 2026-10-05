import Foundation

/// Codes by SMS (migration 20261005000002_sms.sql). The database writes the
/// code, keeps only its hash and hands the text to the send-sms function;
/// the app only ever sees a masked number.
public struct SupabaseSmsRepository: SmsRepository {
    private let client: SupabaseClient

    public init(client: SupabaseClient) { self.client = client }

    public func status() async throws -> SmsStatus {
        try await client.rpc("my_sms_status")
    }

    public func requestCode(_ purpose: SmsPurpose, invoiceID: UUID?, phone: String?,
                            resend: Bool) async throws -> SmsChallenge {
        var body: [String: AnyEncodable] = ["p_purpose": AnyEncodable(purpose.rawValue),
                                            "p_resend": AnyEncodable(resend)]
        if let invoiceID { body["p_invoice_id"] = AnyEncodable(invoiceID.uuidString) }
        if let phone { body["p_phone"] = AnyEncodable(phone) }
        return try await client.rpc("request_sms_code", body: body)
    }

    public func confirm(_ purpose: SmsPurpose, code: String, invoiceID: UUID?) async throws -> SmsConfirmation {
        var body: [String: AnyEncodable] = [
            "p_purpose": AnyEncodable(purpose.rawValue),
            "p_code": AnyEncodable(MobileNumber.code(code))
        ]
        if let invoiceID { body["p_invoice_id"] = AnyEncodable(invoiceID.uuidString) }
        return try await client.rpc("confirm_sms_code", body: body)
    }
}
