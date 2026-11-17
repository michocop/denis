import Foundation

/// An energy contract the company signed for a client, typed in by hand in
/// the owner's private book (table `signed_contracts`). It carries what the
/// renewal needs -- the échéance -- and what the termination letter to the
/// previous supplier needs.
public struct SignedContract: Identifiable, Hashable, Codable, Sendable {
    public enum ClientKind: String, Codable, Sendable, CaseIterable {
        case particulier, professionnel
    }

    public enum Energy: String, Codable, Sendable, CaseIterable {
        case electricite, gaz

        public var label: String { self == .electricite ? "Électricité" : "Gaz" }
        /// What the letter says is supplied.
        public var supplyLabel: String { self == .electricite ? "d'électricité" : "de gaz naturel" }
        /// The meter's name differs by energy: PDL/PRM for power, PCE for gas.
        public var deliveryPointLabel: String {
            self == .electricite ? "Point de livraison (PDL/PRM)" : "Point de comptage (PCE)"
        }
    }

    public var id: UUID
    public var clientKind: ClientKind
    public var clientName: String
    public var signatoryName: String?
    public var signatoryTitle: String?
    public var siret: String?
    public var phone: String?
    public var email: String?
    public var address: String?
    public var postalCode: String?
    public var city: String?
    public var siteAddress: String?
    public var energy: Energy
    public var deliveryPoint: String?
    public var previousSupplier: String?
    public var previousSupplierAddress: String?
    public var previousReference: String?
    /// Calendar days as the database stores them, "2027-03-31": kept as text
    /// so no time zone can move a date by one day on its way through.
    public var terminationOn: String?
    public var newSupplier: String?
    public var signedOn: String?
    public var startsOn: String?
    public var endsOn: String?
    public var notes: String?

    public init(id: UUID = UUID(), clientKind: ClientKind = .professionnel, clientName: String = "",
                signatoryName: String? = nil, signatoryTitle: String? = nil, siret: String? = nil,
                phone: String? = nil, email: String? = nil, address: String? = nil,
                postalCode: String? = nil, city: String? = nil, siteAddress: String? = nil,
                energy: Energy = .electricite, deliveryPoint: String? = nil,
                previousSupplier: String? = nil, previousSupplierAddress: String? = nil,
                previousReference: String? = nil, terminationOn: String? = nil,
                newSupplier: String? = nil, signedOn: String? = nil, startsOn: String? = nil,
                endsOn: String? = nil, notes: String? = nil) {
        self.id = id; self.clientKind = clientKind; self.clientName = clientName
        self.signatoryName = signatoryName; self.signatoryTitle = signatoryTitle; self.siret = siret
        self.phone = phone; self.email = email; self.address = address
        self.postalCode = postalCode; self.city = city; self.siteAddress = siteAddress
        self.energy = energy; self.deliveryPoint = deliveryPoint
        self.previousSupplier = previousSupplier; self.previousSupplierAddress = previousSupplierAddress
        self.previousReference = previousReference; self.terminationOn = terminationOn
        self.newSupplier = newSupplier; self.signedOn = signedOn; self.startsOn = startsOn
        self.endsOn = endsOn; self.notes = notes
    }

    public var isProfessional: Bool { clientKind == .professionnel }

    /// "12 rue des Lilas, 59000 Lille", or nil when nothing was typed.
    public var postalAddress: String? {
        let town = [postalCode, city].compactMap { $0?.nonBlank }.joined(separator: " ")
        let parts = [address?.nonBlank, town.nonBlank].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The site supplied: its own address when typed, else the client's.
    public var suppliedSiteAddress: String? { siteAddress?.nonBlank ?? postalAddress }
}

/// Calendar days in the device's time zone, to and from the database's
/// "yyyy-MM-dd".
public enum ContractDay {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let longFrench: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    public static func date(_ day: String?) -> Date? {
        guard let day, !day.isEmpty else { return nil }
        return formatter.date(from: String(day.prefix(10)))
    }

    public static func string(_ date: Date) -> String {
        return formatter.string(from: date)
    }

    /// "31 mars 2027", "1er avril 2027" -- the first of the month is written
    /// as French letters write it.
    public static func long(_ date: Date) -> String {
        let text = longFrench.string(from: date)
        if Calendar.current.component(.day, from: date) == 1, text.hasPrefix("1 ") {
            return "1er " + text.dropFirst(2)
        }
        return text
    }

    public static func long(_ day: String?) -> String? { date(day).map(long) }

    /// Whole days from today to that day: 0 today, negative once past.
    public static func daysUntil(_ day: String?, from now: Date = .now) -> Int? {
        guard let target = date(day) else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                       to: calendar.startOfDay(for: target)).day
    }
}

/// The book in the order it is worked: the next échéance first, then the
/// contracts with no date, then those already past (most recent first).
public struct ContractBook: Sendable {
    public let upcoming: [SignedContract]
    public let undated: [SignedContract]
    public let expired: [SignedContract]

    public init(_ contracts: [SignedContract], now: Date = .now) {
        var upcoming: [(Int, SignedContract)] = []
        var expired: [(Int, SignedContract)] = []
        var undated: [SignedContract] = []
        for contract in contracts {
            if let days = ContractDay.daysUntil(contract.endsOn, from: now) {
                if days >= 0 { upcoming.append((days, contract)) } else { expired.append((days, contract)) }
            } else {
                undated.append(contract)
            }
        }
        self.upcoming = upcoming.sorted { $0.0 < $1.0 }.map(\.1)
        self.expired = expired.sorted { $0.0 > $1.0 }.map(\.1)
        self.undated = undated.sorted {
            $0.clientName.localizedCaseInsensitiveCompare($1.clientName) == .orderedAscending
        }
    }

    public var isEmpty: Bool { upcoming.isEmpty && undated.isEmpty && expired.isEmpty }
}

public protocol SignedContractsRepository: Sendable {
    /// Whether this account holds the book (the `has_contract_book` RPC). Not
    /// a screen-only check: the table itself refuses everybody else.
    func hasAccess() async throws -> Bool
    func contracts() async throws -> [SignedContract]
    /// Creates or replaces the contract with this id.
    func save(_ contract: SignedContract) async throws -> SignedContract
    func delete(id: UUID) async throws
}

extension String {
    /// The text trimmed, or nil when nothing is left.
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// In memory, for previews and the demo.
public actor PreviewSignedContractsRepository: SignedContractsRepository {
    private var rows: [SignedContract]
    private let access: Bool

    public init(hasAccess: Bool = true, contracts: [SignedContract] = PreviewSignedContractsRepository.samples()) {
        self.access = hasAccess
        self.rows = contracts
    }

    public func hasAccess() async throws -> Bool { access }
    public func contracts() async throws -> [SignedContract] { rows }

    public func save(_ contract: SignedContract) async throws -> SignedContract {
        if let index = rows.firstIndex(where: { $0.id == contract.id }) {
            rows[index] = contract
        } else {
            rows.append(contract)
        }
        return contract
    }

    public func delete(id: UUID) async throws { rows.removeAll { $0.id == id } }

    public static func samples(now: Date = .now) -> [SignedContract] {
        func day(_ offset: Int) -> String {
            ContractDay.string(Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now)
        }
        return [
            SignedContract(clientKind: .professionnel, clientName: "Boulangerie Martin",
                           signatoryName: "Sophie Martin", signatoryTitle: "Gérante",
                           siret: "81234567800012", address: "4 place du Marché",
                           postalCode: "59000", city: "Lille", energy: .electricite,
                           deliveryPoint: "14 52 36 98 74 12 30", previousSupplier: "EDF Entreprises",
                           previousSupplierAddress: "Service Clients\nTSA 21941\n62978 Arras Cedex 9",
                           previousReference: "1-ABC2345", terminationOn: day(20),
                           newSupplier: "Ekwateur", signedOn: day(-10), startsOn: day(20),
                           endsOn: day(75)),
            SignedContract(clientKind: .particulier, clientName: "Thomas Dubois",
                           address: "12 rue des Lilas", postalCode: "59310", city: "Orchies",
                           energy: .gaz, deliveryPoint: "GI 123 456", previousSupplier: "Engie",
                           newSupplier: "TotalEnergies", signedOn: day(-30), startsOn: day(-20),
                           endsOn: day(345)),
            SignedContract(clientKind: .professionnel, clientName: "Garage du Centre",
                           city: "Douai", energy: .electricite, newSupplier: "Vattenfall"),
        ]
    }
}
