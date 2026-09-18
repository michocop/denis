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
    func notifications() async throws -> [AppNotification]
    func markNotificationsRead() async throws
}

public struct AppNotification: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var kind: String
    public var payload: [String: String]
    public var readAt: Date?
    public var createdAt: Date

    public var title: String {
        switch kind {
        case "stage_advanced": return "Votre recommandation a avancé"
        case "reward_earned":  return "Récompense acquise"
        case "payout_sent":    return "Paiement en route"
        default:               return "Mise à jour"
        }
    }

    public var detail: String {
        switch kind {
        case "stage_advanced", "reward_earned":
            let filleul = payload["filleul"] ?? ""
            let stage = payload["stage_label"] ?? ""
            return "\(filleul) — \(stage)"
        case "payout_sent":
            let number = payload["invoice_number"] ?? ""
            return "Facture \(number)"
        default:
            return ""
        }
    }

    public var icon: String {
        switch kind {
        case "reward_earned": return "gift.fill"
        case "payout_sent":   return "eurosign.circle.fill"
        default:              return "arrow.forward.circle.fill"
        }
    }
}
