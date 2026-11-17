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
    public var businessStatus: BusinessStatus? = nil
    /// The last contract this apporteur signed, and whether its PDF is filed.
    public var contractId: UUID? = nil
    public var contractSignedAt: Date? = nil
    public var contractPdfReady: Bool? = nil

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

/// An invitation that has been emailed. The code is kept to read out if the
/// email does not arrive.
public struct Invite: Hashable, Codable, Sendable {
    public var code: String
    public var email: String

    public init(code: String, email: String) {
        self.code = code; self.email = email
    }
}

public protocol AdminRepository: Sendable {
    func members() async throws -> [MemberOverview]
    func setStatus(profileID: UUID, status: String) async throws
    func approve(profileID: UUID) async throws
    /// Creates the invitation and emails it (the send-invite function).
    func createInvite(email: String, role: UserRole, autoActivate: Bool) async throws -> Invite
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

/// Where an apporteur stands against the particulier's ceiling (the
/// `commission_cap` RPC): a particulier may be invoiced 2 400 € of
/// commissions a calendar year, and past it no invoice is issued until they
/// give a SIRET. Home warns from 1 800 €.
public struct CommissionCap: Hashable, Codable, Sendable {
    public var particulier: Bool
    public var year: Int
    /// What this year's invoices come to, credit notes deducted.
    public var total: Decimal
    public var cap: Decimal
    public var alertFrom: Decimal

    public init(particulier: Bool, year: Int, total: Decimal,
                cap: Decimal = 2400, alertFrom: Decimal = 1800) {
        self.particulier = particulier; self.year = year; self.total = total
        self.cap = cap; self.alertFrom = alertFrom
    }

    public enum Alert: Equatable, Sendable {
        /// Close to the ceiling: said before an invoice is refused.
        case approaching
        /// At it: the next commissions wait for a SIRET.
        case reached
    }

    /// Nothing to say below the alert, or to anyone with a SIRET.
    public var alert: Alert? {
        guard particulier, total >= alertFrom else { return nil }
        return total >= cap ? .reached : .approaching
    }

    public var title: String {
        alert == .reached ? "Plafond atteint" : "Plafond de \(Self.euros(cap)) par an"
    }

    public var message: String {
        alert == .reached
            ? "Vos commissions de \(year) ont atteint \(Self.euros(cap)). Pour recevoir les suivantes, renseignez votre SIRET (société ou micro-entreprise)."
            : "Vous avez reçu \(Self.euros(total)) de commissions en \(year). Au-delà de \(Self.euros(cap)) par année civile, vous devez exercer en société ou en micro-entreprise et renseigner votre SIRET."
    }

    /// Cents only when there are some: "1 850 €", "1 850,50 €". Rounded to
    /// the euro, 2 399,60 € would read as the ceiling it has not reached.
    static func euros(_ amount: Decimal) -> String {
        var value = amount, whole = Decimal()
        NSDecimalRound(&whole, &value, 0, .down)
        return Money.euros(amount, cents: whole != amount)
    }
}

public protocol CommissionsRepository: Sendable {
    func statement(year: Int?) async throws -> [CommissionLine]
    /// The signed-in apporteur's standing against the particulier's ceiling.
    func commissionCap() async throws -> CommissionCap
}

