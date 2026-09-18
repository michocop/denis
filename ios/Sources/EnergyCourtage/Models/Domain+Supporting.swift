import Foundation

// MARK: - Profile

public struct Profile: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var role: UserRole
    public var firstName: String
    public var lastName: String
    public var email: String
    public var phone: String?
    public var companyName: String?
    public var siret: String?
    public var city: String?
    public var vatLiable: Bool
    /// Self-billing is only lawful with a prior mandate, so the app has to know
    /// whether this apporteur has signed one.
    public var billingMandateSignedAt: Date?

    public var fullName: String { "\(firstName) \(lastName)" }
    public var initials: String {
        "\(firstName.prefix(1))\(lastName.prefix(1))".uppercased()
    }
    public var canBeInvoiced: Bool { billingMandateSignedAt != nil }

    public init(id: UUID, role: UserRole, firstName: String, lastName: String, email: String,
                phone: String? = nil, companyName: String? = nil, siret: String? = nil,
                city: String? = nil, vatLiable: Bool = false,
                billingMandateSignedAt: Date? = nil) {
        self.id = id; self.role = role; self.firstName = firstName; self.lastName = lastName
        self.email = email; self.phone = phone; self.companyName = companyName
        self.siret = siret; self.city = city; self.vatLiable = vatLiable
        self.billingMandateSignedAt = billingMandateSignedAt
    }
}

// MARK: - Dashboard

public struct DashboardStats: Hashable, Codable, Sendable {
    public var activeCount: Int
    public var archivedCount: Int
    public var pendingTotal: Decimal
    public var earnedTotal: Decimal
    public var paidTotal: Decimal
    public var conversionRate: Double

    public init(activeCount: Int = 0, archivedCount: Int = 0, pendingTotal: Decimal = 0,
                earnedTotal: Decimal = 0, paidTotal: Decimal = 0, conversionRate: Double = 0) {
        self.activeCount = activeCount; self.archivedCount = archivedCount
        self.pendingTotal = pendingTotal; self.earnedTotal = earnedTotal
        self.paidTotal = paidTotal; self.conversionRate = conversionRate
    }
}

// MARK: - Chat

public struct ChatThread: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case direct, group, ticket }

    public let id: UUID
    public var kind: Kind
    public var title: String?
    public var counterpartName: String
    public var lastMessage: String?
    public var lastMessageAt: Date?
    public var unreadCount: Int
    public var pinned: Bool
    public var archived: Bool

    public init(id: UUID, kind: Kind, title: String? = nil, counterpartName: String,
                lastMessage: String? = nil, lastMessageAt: Date? = nil,
                unreadCount: Int = 0, pinned: Bool = false, archived: Bool = false) {
        self.id = id; self.kind = kind; self.title = title
        self.counterpartName = counterpartName; self.lastMessage = lastMessage
        self.lastMessageAt = lastMessageAt; self.unreadCount = unreadCount
        self.pinned = pinned; self.archived = archived
    }

    public var displayName: String { title ?? counterpartName }
    public var initials: String {
        displayName.split(separator: " ").prefix(2)
            .map { $0.prefix(1) }.joined().uppercased()
    }
}

public struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let threadID: UUID
    public let senderID: UUID
    public let senderName: String
    public let body: String?
    public let createdAt: Date

    public init(id: UUID, threadID: UUID, senderID: UUID, senderName: String,
                body: String?, createdAt: Date) {
        self.id = id; self.threadID = threadID; self.senderID = senderID
        self.senderName = senderName; self.body = body; self.createdAt = createdAt
    }
}

// MARK: - Invoice

/// Mirrors `invoice_document()` exactly. One shape for the PDF renderer and
/// the in-app viewer, so what is signed is what was shown.
///
/// Property names are the camelCase of the JSON keys on purpose: the decoder
/// applies `.convertFromSnakeCase`, which rewrites incoming keys before any
/// CodingKey is consulted, so declaring snake_case CodingKeys here would stop
/// every one of them matching.
public struct InvoiceDocument: Hashable, Codable, Sendable {
    public struct Party: Hashable, Codable, Sendable {
        public var name: String
        public var company: String?
        public var city: String?
        public var siret: String?
    }

    public struct Attestation: Hashable, Codable, Sendable {
        public var soussigne: String
        public var misEnRelation: String?
        public var avec: String
        public var prestation: String
        public var intervenueLe: String
    }

    public struct Amount: Hashable, Codable, Sendable {
        public var ht: String
        public var vatRate: Decimal
        public var vat: String
        public var ttc: String
        public var currency: String
    }

    public struct Signature: Hashable, Codable, Sendable, Identifiable {
        public var role: String
        public var name: String
        public var signed: Bool
        public var signedAt: Date?

        public var id: String { role }
        public var label: String {
            role == "apporteur" ? "Signature de l'apporteur" : "Signature de l'entreprise"
        }
    }

    public var number: String
    /// Computed by the database over the invoice's canonical text. The client
    /// signs this value rather than reproducing the canonicalisation, which
    /// would otherwise have to stay byte-identical between Swift and SQL.
    public var documentSha256: String?
    public var issuer: Party
    public var apporteur: Party
    public var attestation: Attestation
    public var amount: Amount
    public var legalMentions: String
    public var paymentMethod: String
    public var place: String
    public var issuedOn: String
    public var taxNotice: String?
    public var status: String
    public var signatures: [Signature]

    public var isFullySigned: Bool { signatures.allSatisfy(\.signed) }
}
