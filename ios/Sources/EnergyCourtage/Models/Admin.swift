import Foundation

/// A row of the admin's member list.
public struct MemberOverview: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var fullName: String
    public var email: String
    public var phone: String?
    public var role: UserRole
    public var status: String
    public var vatLiable: Bool
    public var hasMandate: Bool
    /// Whether payment details are held in the client's own banking system.
    /// The account number itself is deliberately not stored here.
    public var bankDetailsOnFile: Bool
    public var totalRecommendations: Int
    public var activeRecommendations: Int
    public var paidTotal: Decimal
    public var owedTotal: Decimal
    public var lastRecommendationAt: Date?

    public var initials: String {
        fullName.split(separator: " ").prefix(2).map { $0.prefix(1) }.joined().uppercased()
    }

    public var isActive: Bool { status == "active" }
    public var isPending: Bool { status == "pending" }

    /// Someone who signed up and has never sent anything is worth a call, and
    /// is invisible in a list sorted by activity.
    public var hasNeverRecommended: Bool { totalRecommendations == 0 }
}

/// A signed invoice waiting to be paid.
public struct PayableInvoice: Identifiable, Hashable, Codable, Sendable {
    public let invoiceId: UUID
    public var number: String
    public var issuedOn: Date
    public var amountTtc: Decimal
    public var apporteurId: UUID
    public var apporteurName: String
    /// Paying someone with no bank details on file cannot work, so the list
    /// says so before the batch is built rather than after the transfer fails.
    public var hasBankDetails: Bool
    public var recommendationId: UUID
    public var filleul: String

    public var id: UUID { invoiceId }
}

public struct Invite: Hashable, Codable, Sendable {
    public var code: String
    public var email: String?
    public var role: UserRole
    public var autoActivate: Bool
    public var expiresAt: Date
}

public protocol AdminRepository: Sendable {
    func members() async throws -> [MemberOverview]
    func setStatus(profileID: UUID, status: String) async throws
    func approve(profileID: UUID) async throws
    func createInvite(email: String?, role: UserRole, autoActivate: Bool) async throws -> Invite
    func payableInvoices() async throws -> [PayableInvoice]
    func payBatch(invoiceIDs: [UUID], reference: String?) async throws
    /// Whether this member's payment details are held in the client's own
    /// banking system. Without a way to set it, nobody was ever payable.
    func setBankDetailsOnFile(profileID: UUID, onFile: Bool, reference: String?) async throws
}

/// A line of the apporteur's own statement — what the app's closing message
/// tells them to declare, and previously gave them no way to produce.
public struct CommissionLine: Identifiable, Hashable, Codable, Sendable {
    public let recommendationId: UUID
    public var year: Int
    public var filleul: String
    public var rewardAmount: Decimal?
    public var rewardStatus: RewardStatus
    public var invoiceNumber: String?
    public var issuedOn: Date?
    public var amountTtc: Decimal?
    public var invoiceStatus: String?

    public var id: UUID { recommendationId }
}

public protocol CommissionsRepository: Sendable {
    func statement(year: Int?) async throws -> [CommissionLine]
}

