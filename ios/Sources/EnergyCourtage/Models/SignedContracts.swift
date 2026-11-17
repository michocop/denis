import Foundation

/// An energy contract the company signed for a client, typed in by hand in
/// the owner's private book (table `signed_contracts`). It carries what the
/// renewal needs -- the échéance -- and what the termination letter to the
/// previous supplier needs.
public struct SignedContract: Identifiable, Hashable, Codable, Sendable {
    public enum ClientKind: String, Codable, Sendable, CaseIterable {
        case particulier, professionnel
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
    /// Every meter the contract covers: as many as the client has.
    public var deliveryPoints: [DeliveryPoint]
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
    /// PostgREST's embedded count, `signed_contract_files(count)`: read only,
    /// absent from a row the server sends back after a save.
    public var signedContractFiles: [FileCount]?

    public struct FileCount: Codable, Hashable, Sendable { public var count: Int }

    public init(id: UUID = UUID(), clientKind: ClientKind = .professionnel, clientName: String = "",
                signatoryName: String? = nil, signatoryTitle: String? = nil, siret: String? = nil,
                phone: String? = nil, email: String? = nil, address: String? = nil,
                postalCode: String? = nil, city: String? = nil,
                deliveryPoints: [DeliveryPoint] = [],
                previousSupplier: String? = nil, previousSupplierAddress: String? = nil,
                previousReference: String? = nil, terminationOn: String? = nil,
                newSupplier: String? = nil, signedOn: String? = nil, startsOn: String? = nil,
                endsOn: String? = nil, notes: String? = nil, fileCount: Int? = nil) {
        self.id = id; self.clientKind = clientKind; self.clientName = clientName
        self.signatoryName = signatoryName; self.signatoryTitle = signatoryTitle; self.siret = siret
        self.phone = phone; self.email = email; self.address = address
        self.postalCode = postalCode; self.city = city
        self.deliveryPoints = deliveryPoints
        self.previousSupplier = previousSupplier; self.previousSupplierAddress = previousSupplierAddress
        self.previousReference = previousReference; self.terminationOn = terminationOn
        self.newSupplier = newSupplier; self.signedOn = signedOn; self.startsOn = startsOn
        self.endsOn = endsOn; self.notes = notes
        self.signedContractFiles = fileCount.map { [FileCount(count: $0)] }
    }

    public var isProfessional: Bool { clientKind == .professionnel }

    public var fileCount: Int? {
        get { signedContractFiles?.first?.count }
        set { signedContractFiles = newValue.map { [FileCount(count: $0)] } }
    }

    /// The meters actually filled in: a row left blank in the form is not one.
    public var filledPoints: [DeliveryPoint] {
        deliveryPoints.filter { $0.number.nonBlank != nil }
    }

    /// Power, gas, or both, in that order.
    public var energies: [Energy] {
        Energy.allCases.filter { energy in filledPoints.contains { $0.energy == energy } }
    }

    /// "d'électricité", "de gaz naturel", "d'électricité et de gaz naturel".
    public var supplyLabel: String {
        switch energies {
        case [.electricite]: return "d'électricité"
        case [.gaz]:         return "de gaz naturel"
        case []:             return "d'énergie"
        default:             return "d'électricité et de gaz naturel"
        }
    }

    /// "12 rue des Lilas, 59000 Lille", or nil when nothing was typed.
    public var postalAddress: String? {
        let town = [postalCode, city].compactMap { $0?.nonBlank }.joined(separator: " ")
        let parts = [address?.nonBlank, town.nonBlank].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Everything the search box looks through.
    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let compact = { (text: String) in text.lowercased().filter { !$0.isWhitespace } }
        var haystack = [clientName, signatoryName, siret, phone, email, address, postalCode, city,
                        previousSupplier, previousReference, newSupplier, notes]
            .compactMap { $0?.lowercased() }
        for point in deliveryPoints {
            haystack += [point.number.lowercased(), compact(point.number),
                         point.label?.lowercased() ?? "", point.site?.lowercased() ?? ""]
        }
        let text = haystack.joined(separator: " ")
        return words.allSatisfy { word in text.contains(word) || text.contains(compact(word)) }
    }

    /// A new contract for the same client: the client, not the deal. For a
    /// client with power at one supplier and gas at another, or a renewal.
    public func duplicate() -> SignedContract {
        var copy = SignedContract(clientKind: clientKind, clientName: clientName,
                                  signatoryName: signatoryName, signatoryTitle: signatoryTitle,
                                  siret: siret, phone: phone, email: email, address: address,
                                  postalCode: postalCode, city: city)
        copy.deliveryPoints = deliveryPoints.map { DeliveryPoint(energy: $0.energy, number: $0.number,
                                                                 label: $0.label, site: $0.site) }
        return copy
    }
}

public extension SignedContract {
    typealias Energy = EnergyKind
}

public enum EnergyKind: String, Codable, Sendable, CaseIterable, Hashable {
    case electricite, gaz

    public var label: String { self == .electricite ? "Électricité" : "Gaz" }
    /// The meter's name differs by energy: PDL/PRM for power, PCE for gas.
    public var pointName: String { self == .electricite ? "PDL/PRM" : "PCE" }
    public var deliveryPointLabel: String {
        self == .electricite ? "Point de livraison (PDL/PRM)" : "Point de comptage (PCE)"
    }
    public var icon: String { self == .electricite ? "bolt.fill" : "flame.fill" }
}

/// One meter: a PDL/PRM for power or a PCE for gas, with the site it supplies.
/// Stored as JSON in `delivery_points`; one-word keys, so the snake_case
/// decoding the client applies everywhere leaves them alone.
public struct DeliveryPoint: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var energy: EnergyKind
    public var number: String
    /// "Siège", "Entrepôt", "Boutique rue Nationale"…
    public var label: String?
    /// The site's address, when it is not the client's.
    public var site: String?

    public init(id: UUID = UUID(), energy: EnergyKind = .electricite, number: String = "",
                label: String? = nil, site: String? = nil) {
        self.id = id; self.energy = energy; self.number = number; self.label = label; self.site = site
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        energy = (try? c.decode(EnergyKind.self, forKey: .energy)) ?? .electricite
        number = (try? c.decode(String.self, forKey: .number)) ?? ""
        label = try? c.decode(String.self, forKey: .label)
        site = try? c.decode(String.self, forKey: .site)
    }

    /// The numbers pasted in one go -- one per line, or separated by commas
    /// or semicolons -- as points of one energy. Spaces inside a number are
    /// kept as typed.
    public static func parse(_ text: String, energy: EnergyKind) -> [DeliveryPoint] {
        text.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == ";" })
            .compactMap { String($0).nonBlank }
            .map { DeliveryPoint(energy: energy, number: $0) }
    }
}

/// A paper filed with a contract: the signed contract, a bill, an ID.
public struct ContractFile: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var contractId: UUID
    public var storagePath: String
    public var filename: String
    public var byteSize: Int64?
    public var mimeType: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), contractId: UUID, storagePath: String, filename: String,
                byteSize: Int64?, mimeType: String?, createdAt: Date = .now) {
        self.id = id; self.contractId = contractId; self.storagePath = storagePath
        self.filename = filename; self.byteSize = byteSize; self.mimeType = mimeType
        self.createdAt = createdAt
    }

    public var isPDF: Bool { mimeType == "application/pdf" || filename.lowercased().hasSuffix(".pdf") }
    public var sizeLabel: String? {
        byteSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
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
    /// Deletes the contract and its files.
    func delete(id: UUID) async throws

    func files(contractID: UUID) async throws -> [ContractFile]
    func addFile(_ upload: DocumentUpload, to contractID: UUID) async throws -> ContractFile
    func data(of file: ContractFile) async throws -> Data
    func removeFile(_ file: ContractFile) async throws
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
    private var stored: [UUID: (ContractFile, Data)] = [:]
    private let access: Bool

    public init(hasAccess: Bool = true, contracts: [SignedContract] = PreviewSignedContractsRepository.samples()) {
        self.access = hasAccess
        self.rows = contracts
    }

    public func hasAccess() async throws -> Bool { access }

    public func contracts() async throws -> [SignedContract] {
        rows.map { row in
            var row = row
            row.fileCount = stored.values.filter { $0.0.contractId == row.id }.count
            return row
        }
    }

    public func save(_ contract: SignedContract) async throws -> SignedContract {
        var contract = contract
        contract.signedContractFiles = nil
        if let index = rows.firstIndex(where: { $0.id == contract.id }) {
            rows[index] = contract
        } else {
            rows.append(contract)
        }
        return contract
    }

    public func delete(id: UUID) async throws {
        rows.removeAll { $0.id == id }
        stored = stored.filter { $0.value.0.contractId != id }
    }

    public func files(contractID: UUID) async throws -> [ContractFile] {
        stored.values.map(\.0).filter { $0.contractId == contractID }.sorted { $0.createdAt < $1.createdAt }
    }

    public func addFile(_ upload: DocumentUpload, to contractID: UUID) async throws -> ContractFile {
        guard upload.data.count <= DocumentUpload.maxBytes else { throw DocumentError.tooLarge }
        let file = ContractFile(contractId: contractID,
                                storagePath: "\(contractID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).\(upload.fileExtension)",
                                filename: upload.filename, byteSize: Int64(upload.data.count),
                                mimeType: upload.mimeType)
        stored[file.id] = (file, upload.data)
        return file
    }

    public func data(of file: ContractFile) async throws -> Data { stored[file.id]?.1 ?? Data() }
    public func removeFile(_ file: ContractFile) async throws { stored[file.id] = nil }

    public static func samples(now: Date = .now) -> [SignedContract] {
        func day(_ offset: Int) -> String {
            ContractDay.string(Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now)
        }
        return [
            SignedContract(clientKind: .professionnel, clientName: "Boulangerie Martin",
                           signatoryName: "Sophie Martin", signatoryTitle: "Gérante",
                           siret: "81234567800012", address: "4 place du Marché",
                           postalCode: "59000", city: "Lille",
                           deliveryPoints: [
                               DeliveryPoint(energy: .electricite, number: "14 52 36 98 74 12 30", label: "Boutique"),
                               DeliveryPoint(energy: .electricite, number: "14 52 36 98 74 12 31", label: "Fournil",
                                             site: "6 rue de la Gare, 59000 Lille"),
                               DeliveryPoint(energy: .gaz, number: "GI 052 114", label: "Fournil"),
                           ],
                           previousSupplier: "EDF Entreprises",
                           previousSupplierAddress: "Service Clients\nTSA 21941\n62978 Arras Cedex 9",
                           previousReference: "1-ABC2345", terminationOn: day(20),
                           newSupplier: "Ekwateur", signedOn: day(-10), startsOn: day(20),
                           endsOn: day(75)),
            SignedContract(clientKind: .particulier, clientName: "Thomas Dubois",
                           address: "12 rue des Lilas", postalCode: "59310", city: "Orchies",
                           deliveryPoints: [DeliveryPoint(energy: .gaz, number: "GI 123 456")],
                           previousSupplier: "Engie",
                           newSupplier: "TotalEnergies", signedOn: day(-30), startsOn: day(-20),
                           endsOn: day(345)),
            SignedContract(clientKind: .professionnel, clientName: "Garage du Centre",
                           city: "Douai", newSupplier: "Vattenfall"),
        ]
    }
}
