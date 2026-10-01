import Foundation

// MARK: - Mes documents

/// One line under "Fichiers": a reconnaissance d'honoraires or an avoir.
/// Mirrors `my_documents()`.
public struct DocumentItem: Identifiable, Hashable, Decodable, Sendable {
    public let invoiceId: UUID
    public let number: String
    /// "honoraires" or "avoir"
    public let kind: String
    /// awaiting_signatures | signed | paid | draft
    public let status: String
    public let amountTtc: Decimal
    public let issuedAt: Date
    public let filleulName: String
    public let apporteurName: String
    public let recommendationActive: Bool
    public let hasPdf: Bool

    public var id: UUID { invoiceId }

    public init(invoiceId: UUID, number: String, kind: String, status: String,
                amountTtc: Decimal, issuedAt: Date, filleulName: String,
                apporteurName: String, recommendationActive: Bool, hasPdf: Bool) {
        self.invoiceId = invoiceId; self.number = number; self.kind = kind
        self.status = status; self.amountTtc = amountTtc; self.issuedAt = issuedAt
        self.filleulName = filleulName; self.apporteurName = apporteurName
        self.recommendationActive = recommendationActive; self.hasPdf = hasPdf
    }

    public var title: String { kind == "avoir" ? "Avoir" : "Reconnaissance d'honoraires" }

    public var tag: DocumentTag {
        switch status {
        case "signed": return .signed
        case "paid":   return .paid
        default:       return .toSign
        }
    }
}

/// "Étiquettes".
public enum DocumentTag: String, CaseIterable, Identifiable, Sendable {
    case toSign, signed, paid
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .toSign: return "À signer"
        case .signed: return "Signé"
        case .paid:   return "Payé"
        }
    }
}

/// "Période".
public enum DocumentPeriod: String, CaseIterable, Identifiable, Sendable {
    case all, last30Days, thisYear
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .all:        return "Toute période"
        case .last30Days: return "30 derniers jours"
        case .thisYear:   return "Cette année"
        }
    }
    public func contains(_ date: Date, now: Date = .now) -> Bool {
        switch self {
        case .all:        return true
        case .last30Days: return date >= now.addingTimeInterval(-30 * 86_400)
        case .thisYear:
            return Calendar.current.component(.year, from: date)
                == Calendar.current.component(.year, from: now)
        }
    }
}

/// The filters above "Fichiers". Every one defaults to "everything".
public struct DocumentFilters: Hashable, Sendable {
    public var query = ""
    public var period: DocumentPeriod = .all
    public var tag: DocumentTag?
    /// "Actifs": nil = all, true = active recommendations, false = archived
    public var active: Bool?
    /// "Tous les types": nil = all, else "honoraires" or "avoir"
    public var kind: String?

    public init() {}

    public func apply(to items: [DocumentItem], now: Date = .now) -> [DocumentItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            (q.isEmpty
             || item.number.localizedCaseInsensitiveContains(q)
             || item.filleulName.localizedCaseInsensitiveContains(q)
             || item.apporteurName.localizedCaseInsensitiveContains(q)
             || item.title.localizedCaseInsensitiveContains(q))
            && period.contains(item.issuedAt, now: now)
            && (tag == nil || item.tag == tag)
            && (active == nil || item.recommendationActive == active)
            && (kind == nil || item.kind == kind)
        }
    }
}

// MARK: - Justificatifs

public enum JustificatifKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case carteIdentite = "carte_identite"
    case rib

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .carteIdentite: return "Ma carte d'identité"
        case .rib:           return "Mon relevé d'identité bancaire"
        }
    }
    public var systemImage: String {
        switch self {
        case .carteIdentite: return "person"
        case .rib:           return "building.columns"
        }
    }
}

/// The live file of one kind, from `my_justificatifs`.
public struct Justificatif: Identifiable, Hashable, Decodable, Sendable {
    public let id: UUID
    public let kind: JustificatifKind
    public let filename: String
    public let uploadedAt: Date
    public let expiresAt: Date

    public init(id: UUID, kind: JustificatifKind, filename: String,
                uploadedAt: Date, expiresAt: Date) {
        self.id = id; self.kind = kind; self.filename = filename
        self.uploadedAt = uploadedAt; self.expiresAt = expiresAt
    }
}

public protocol DocumentsRepository: Sendable {
    func documents() async throws -> [DocumentItem]
    func justificatifs() async throws -> [Justificatif]
    func upload(_ kind: JustificatifKind, data: Data, filename: String,
                contentType: String) async throws
    /// "Contact de Michel AJ": who invited this apporteur.
    func contactName() async throws -> String?
}
