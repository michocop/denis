import Foundation

public struct SupabaseAdminRepository: AdminRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func members() async throws -> [MemberOverview] {
        // RLS on the underlying tables means an apporteur querying this sees
        // only their own row, so the same view serves both sides.
        try await client.get("member_overview", query: [
            URLQueryItem(name: "order", value: "full_name.asc")
        ])
    }

    public func setStatus(profileID: UUID, status: String) async throws {
        try await client.rpcVoid("set_member_status", body: [
            "p_profile_id": AnyEncodable(profileID.uuidString),
            "p_status": AnyEncodable(status)
        ])
    }

    public func approve(profileID: UUID) async throws {
        try await client.rpcVoid("approve_member", body: [
            "p_profile_id": AnyEncodable(profileID.uuidString)
        ])
    }

    public func createInvite(email: String?, role: UserRole,
                             autoActivate: Bool) async throws -> Invite {
        var body: [String: AnyEncodable] = [
            "p_role": AnyEncodable(role.rawValue),
            "p_auto_activate": AnyEncodable(autoActivate)
        ]
        if let email, !email.isEmpty { body["p_email"] = AnyEncodable(email) }
        return try await client.rpc("create_invite", body: body)
    }

    public func payableInvoices() async throws -> [PayableInvoice] {
        try await client.get("payable_invoices", query: [
            URLQueryItem(name: "order", value: "apporteur_name.asc,issued_on.asc")
        ])
    }

    public func payBatch(invoiceIDs: [UUID], reference: String?) async throws {
        var body: [String: AnyEncodable] = [
            "p_invoice_ids": AnyEncodable(invoiceIDs.map(\.uuidString))
        ]
        if let reference { body["p_reference"] = AnyEncodable(reference) }
        try await client.rpcVoid("create_payout_batch", body: body)
    }
}

public struct SupabaseCommissionsRepository: CommissionsRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func statement(year: Int?) async throws -> [CommissionLine] {
        var query = [URLQueryItem(name: "order", value: "issued_on.desc.nullslast")]
        if let year { query.append(URLQueryItem(name: "year", value: "eq.\(year)")) }
        return try await client.get("commission_statement", query: query)
    }

}

/// Reads `notification_feed`, which renders the title and body in SQL so the
/// row here and a lock-screen banner cannot say different things.
public struct SupabaseNotificationsRepository: NotificationsRepository {
    private let client: SupabaseClient
    public init(client: SupabaseClient) { self.client = client }

    public func notifications() async throws -> [AppNotification] {
        try await client.get("notification_feed", query: [
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "50")
        ])
    }

    public func unreadCount() async throws -> Int {
        try await client.rpc("unread_notification_count")
    }

    public func markAllRead() async throws {
        try await client.rpcVoid("mark_notifications_read")
    }

    public func register(deviceToken: String) async throws {
        try await client.rpcVoid("register_device_token", body: [
            "p_token": AnyEncodable(deviceToken)
        ])
    }
}
