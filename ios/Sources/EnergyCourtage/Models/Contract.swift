import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// How an apporteur works: through a company, or on their own. It decides
/// what the contract and every invoice say about them.
public enum BusinessStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case societe
    case independant

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .societe: "Société"
        case .independant: "Indépendant"
        }
    }

    public var explanation: String {
        switch self {
        case .societe: "SAS, SASU, SARL, EURL… Vos commissions sont facturées au nom de votre société."
        case .independant: "Micro-entrepreneur ou entreprise individuelle, en votre nom propre."
        }
    }

    public var systemImage: String {
        switch self {
        case .societe: "building.2"
        case .independant: "person.crop.square"
        }
    }

    /// The forms offered to choose from; the first is preselected.
    public var legalForms: [String] {
        switch self {
        case .societe: ["SASU", "SAS", "EURL", "SARL", "SA", "SNC"]
        case .independant: ["Micro-entrepreneur", "Entreprise individuelle"]
        }
    }
}

/// A contract as it was signed: the server keeps who signed, under which
/// status, from which verified mobile, and files the PDF.
public struct ApporteurContract: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var profileId: UUID
    public var signedAt: Date
    public var businessStatus: BusinessStatus
    public var contractVersion: String
    public var signerFullName: String
    public var companyName: String?
    public var otpVerified: Bool
    public var otpPhone: String?
    public var pdfPath: String?

    public init(id: UUID = UUID(), profileId: UUID, signedAt: Date = .now,
                businessStatus: BusinessStatus, contractVersion: String,
                signerFullName: String, companyName: String? = nil,
                otpVerified: Bool, otpPhone: String? = nil, pdfPath: String? = nil) {
        self.id = id; self.profileId = profileId; self.signedAt = signedAt
        self.businessStatus = businessStatus; self.contractVersion = contractVersion
        self.signerFullName = signerFullName; self.companyName = companyName
        self.otpVerified = otpVerified; self.otpPhone = otpPhone; self.pdfPath = pdfPath
    }

    /// What is printed on the PDF and read out on the phone: CT-5F0C2A1E.
    public var reference: String { "CT-" + id.uuidString.prefix(8).uppercased() }

    /// The file name the share sheet and Files show.
    public var fileName: String { "Contrat apporteur \(reference).pdf" }
}

public protocol ContractRepository: Sendable {
    /// The last contract this person signed; nil before they sign one. An
    /// apporteur reads their own, an admin anyone's.
    func contract(for profileID: UUID) async throws -> ApporteurContract?
    /// Signs the contract and its annex, the billing mandate, with the code
    /// confirmed just before. The digests are those of the texts shown.
    func sign(status: BusinessStatus, contractSHA256: String,
              mandateSHA256: String) async throws -> ApporteurContract
    /// The filed PDF, or nil while the server is still preparing it.
    func pdf(of contract: ApporteurContract) async throws -> Data?
}

// MARK: - Demo

/// The demo's one contract, kept for the session so signing it shows on the
/// profile, as it does for real.
actor DemoContractStore {
    static let shared = DemoContractStore()
    private(set) var contract: ApporteurContract?
    func record(_ contract: ApporteurContract) { self.contract = contract }
    func reset() { contract = nil }
}

public struct PreviewContractRepository: ContractRepository {
    public init() {}

    public func contract(for profileID: UUID) async throws -> ApporteurContract? {
        if profileID == DemoChatStore.me { return await DemoContractStore.shared.contract }
        // the company's view: the demo's apporteurs signed theirs long ago
        return ApporteurContract(profileId: profileID, signedAt: .now.addingTimeInterval(-86_400 * 90),
                                 businessStatus: .societe, contractVersion: "demo-1",
                                 signerFullName: "Johann Lefeuvre", companyName: "Lefeuvre Conseil",
                                 otpVerified: true, otpPhone: "+33 6 •• •• •• 11", pdfPath: "demo.pdf")
    }

    public func sign(status: BusinessStatus, contractSHA256: String,
                     mandateSHA256: String) async throws -> ApporteurContract {
        try await Task.sleep(for: .milliseconds(500))
        let contract = ApporteurContract(
            profileId: DemoChatStore.me, businessStatus: status, contractVersion: "demo-1",
            signerFullName: "Johann Lefeuvre",
            companyName: status == .societe ? "Lefeuvre Conseil" : nil,
            otpVerified: true, otpPhone: "+33 6 •• •• •• 78", pdfPath: "demo.pdf")
        await DemoContractStore.shared.record(contract)
        await DemoLegalStore.shared.accept("mandat_facturation")
        await DemoLegalStore.shared.accept("contrat_apporteur")
        return contract
    }

    public func pdf(of contract: ApporteurContract) async throws -> Data? {
        #if canImport(UIKit)
        let texts = try await PreviewLegalRepository().documents()
        return await MainActor.run { DemoContractPDF.render(contract, texts: texts) }
        #else
        return nil
        #endif
    }
}

#if canImport(UIKit)
/// A plain rendering for the demo, where there is no server to file the real
/// one: the texts and the signature certificate, nothing more.
enum DemoContractPDF {
    @MainActor
    static func render(_ contract: ApporteurContract, texts: [LegalDocument]) -> Data {
        // **bold** as it is in the texts, set bold
        func inline(_ text: String) -> String {
            escape(text).replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>",
                                              options: .regularExpression)
        }
        func section(_ title: String?, _ body: String) -> String {
            let html = LegalText.parse(body).map { block -> String in
                switch block {
                case .heading(let t): "<h3>\(inline(t))</h3>"
                case .bullet(let t): "<p class='li'>— \(inline(t))</p>"
                case .paragraph(let t): "<p>\(inline(t))</p>"
                }
            }.joined()
            return (title.map { "<h2>\(escape($0))</h2>" } ?? "") + html
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "dd.MM.yyyy 'à' HH:mm"
        let contractText = texts.first { $0.key == "contrat_apporteur" }
        let mandate = texts.first { $0.key == "mandat_facturation" }
        let html = """
        <html><head><style>
        body { font-family: -apple-system; color: #1C2333; font-size: 10pt; line-height: 1.45; }
        h1 { color: #0A1F4A; font-size: 20pt; margin: 0; } h2 { color: #0A1F4A; font-size: 13pt; margin-top: 18pt; }
        h3 { color: #0A1F4A; font-size: 10.5pt; margin: 12pt 0 2pt; } p { margin: 0 0 6pt; } .li { padding-left: 12pt; }
        .meta { color: #5B6478; font-size: 9pt; } td { padding: 3pt 12pt 3pt 0; vertical-align: top; }
        td.l { color: #6B7385; font-size: 8pt; text-transform: uppercase; letter-spacing: .5pt; }
        </style></head><body>
        <p class='meta'>TRINITY ÉNERGIE — DÉMONSTRATION, SANS VALEUR CONTRACTUELLE</p>
        <h1>Contrat d'apporteur d'affaires</h1>
        <p class='meta'>Réf. \(contract.reference) · \(escape(contract.signerFullName))</p>
        \(contractText.map { section(nil, $0.body) } ?? "")
        \(mandate.map { section("Annexe — " + $0.title, $0.body) } ?? "")
        <h2>Certificat de signature électronique</h2>
        <table>
        <tr><td class='l'>Signataire</td><td>\(escape(contract.signerFullName))</td></tr>
        <tr><td class='l'>Statut</td><td>\(contract.businessStatus.label)\(contract.companyName.map { " — " + escape($0) } ?? "")</td></tr>
        <tr><td class='l'>Date</td><td>\(formatter.string(from: contract.signedAt))</td></tr>
        <tr><td class='l'>Méthode</td><td>Code SMS vérifié · \(contract.otpPhone ?? "")</td></tr>
        </table></body></html>
        """
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(UIMarkupTextPrintFormatter(markupText: html), startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(page.insetBy(dx: 48, dy: 48), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        for index in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
#endif
