import XCTest
@testable import EnergyCourtage

/// The owner's book of signed contracts: its order, what it sends the server,
/// and the termination letter written from it.
final class SignedContractsTests: XCTestCase {

    private let now = ContractDay.date("2026-11-16")!

    private func day(_ offset: Int) -> String {
        ContractDay.string(Calendar.current.date(byAdding: .day, value: offset, to: now)!)
    }

    func testTheBookReadsTheNextEcheanceFirst() {
        let late = SignedContract(clientName: "Late", endsOn: day(400))
        let soon = SignedContract(clientName: "Soon", endsOn: day(30))
        let past = SignedContract(clientName: "Past", endsOn: day(-5))
        let older = SignedContract(clientName: "Older", endsOn: day(-50))
        let none = SignedContract(clientName: "Zed")
        let other = SignedContract(clientName: "abel")

        let book = ContractBook([late, past, none, soon, older, other], now: now)
        XCTAssertEqual(book.upcoming.map(\.clientName), ["Soon", "Late"])
        XCTAssertEqual(book.undated.map(\.clientName), ["abel", "Zed"])
        XCTAssertEqual(book.expired.map(\.clientName), ["Past", "Older"])
    }

    func testDaysKeepTheirCalendarDate() {
        XCTAssertEqual(ContractDay.string(ContractDay.date("2027-03-31")!), "2027-03-31")
        XCTAssertEqual(ContractDay.daysUntil("2026-11-26", from: now), 10)
        XCTAssertEqual(ContractDay.long("2027-04-01"), "1er avril 2027")
        XCTAssertEqual(ContractDay.long("2027-03-31"), "31 mars 2027")
    }

    func testBlankFieldsAreSentAsNullSoTheyClear() throws {
        let contract = SignedContract(clientName: "  Boulangerie  ", signatoryName: "   ",
                                      siret: "812 345 678 00012", endsOn: "2027-01-31")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SupabaseSignedContractsRepository.values(of: contract))) as! [String: Any]
        XCTAssertEqual(json["client_name"] as? String, "Boulangerie")
        XCTAssertTrue(json["signatory_name"] is NSNull)
        XCTAssertTrue(json["notes"] is NSNull)
        XCTAssertEqual(json["siret"] as? String, "81234567800012")
        XCTAssertEqual(json["ends_on"] as? String, "2027-01-31")
        XCTAssertEqual(json["energy"] as? String, "electricite")
    }

    func testARowFromTheServerDecodes() throws {
        let row = """
        [{"id":"7d1f0c1e-4c6b-4d8e-9a0b-1c2d3e4f5a6b","created_by":null,
          "client_kind":"particulier","client_name":"Thomas Dubois","energy":"gaz",
          "delivery_point":"GI123","ends_on":"2027-06-30","termination_on":null,
          "previous_supplier_address":"TSA 1\\n75000 Paris",
          "created_at":"2026-11-16T10:00:00.123+00:00","updated_at":"2026-11-16T10:00:00+00:00"}]
        """
        let rows = try SupabaseClient.decoder.decode([SignedContract].self, from: Data(row.utf8))
        XCTAssertEqual(rows.first?.clientKind, .particulier)
        XCTAssertEqual(rows.first?.energy, .gaz)
        XCTAssertEqual(rows.first?.endsOn, "2027-06-30")
        XCTAssertEqual(rows.first?.previousSupplierAddress, "TSA 1\n75000 Paris")
    }

    func testACompanyLetterSpeaksForTheCompany() {
        let contract = SignedContract(
            clientKind: .professionnel, clientName: "Boulangerie Martin",
            signatoryName: "Sophie Martin", signatoryTitle: "Gérante", siret: "81234567800012",
            address: "4 place du Marché", postalCode: "59000", city: "Lille", energy: .electricite,
            deliveryPoint: "14523698741230", previousSupplier: "EDF Entreprises",
            previousSupplierAddress: "Service Clients\nTSA 21941\n62978 Arras Cedex 9",
            previousReference: "1-ABC2345", terminationOn: "2026-12-01")
        let letter = TerminationLetter(contract: contract, on: now)

        XCTAssertEqual(letter.sender.prefix(4), ["Boulangerie Martin", "Représentée par Sophie Martin, Gérante",
                                                 "4 place du Marché", "59000 Lille"])
        XCTAssertEqual(letter.recipient, ["EDF Entreprises", "Service Clients", "TSA 21941", "62978 Arras Cedex 9"])
        XCTAssertEqual(letter.placeAndDate, "À Lille, le 16 novembre 2026")
        XCTAssertEqual(letter.subject, "Objet : Résiliation du contrat de fourniture d'électricité")
        XCTAssertTrue(letter.references.contains("Point de livraison (PDL/PRM) : 14523698741230"))
        XCTAssertTrue(letter.references.contains("N° client / contrat : 1-ABC2345"))
        let body = letter.paragraphs.joined(separator: " ")
        XCTAssertTrue(body.contains("nous vous informons de notre décision"))
        XCTAssertTrue(body.contains("prendra effet le 1er décembre 2026"))
        XCTAssertEqual(letter.signature, ["Sophie Martin, Gérante", "Pour Boulangerie Martin"])
        XCTAssertTrue(TerminationLetter.missing(in: contract).isEmpty)
    }

    func testAParticulierWritesInTheFirstPerson() {
        let contract = SignedContract(clientKind: .particulier, clientName: "Thomas Dubois",
                                      energy: .gaz, deliveryPoint: "GI123", previousSupplier: "Engie")
        let letter = TerminationLetter(contract: contract, on: now)
        XCTAssertEqual(letter.placeAndDate, "Le 16 novembre 2026")
        XCTAssertEqual(letter.subject, "Objet : Résiliation du contrat de fourniture de gaz naturel")
        XCTAssertTrue(letter.references.contains("Point de comptage (PCE) : GI123"))
        let body = letter.paragraphs.joined(separator: " ")
        XCTAssertTrue(body.contains("je vous informe de ma décision"))
        XCTAssertTrue(body.contains("dans les délais prévus par mon contrat"))
        XCTAssertEqual(letter.signature, ["Thomas Dubois"])
        XCTAssertEqual(letter.recipient, ["Engie", "Service Clients – Résiliation"])
        XCTAssertEqual(TerminationLetter.missing(in: contract),
                       ["l'adresse de l'ancien fournisseur", "le n° de client ou de contrat",
                        "l'adresse du client"])
    }

    func testNoLetterWithoutAPreviousSupplier() {
        XCTAssertFalse(TerminationLetter.canWrite(SignedContract(clientName: "X")))
        XCTAssertTrue(TerminationLetter.canWrite(SignedContract(clientName: "X", previousSupplier: "EDF")))
    }

    func testTheLetterRendersAsAPDF() {
        let contract = PreviewSignedContractsRepository.samples(now: now)[0]
        let data = TerminationLetterPDF.render(TerminationLetter(contract: contract, on: now))
        XCTAssertGreaterThan(data.count, 1000)
        XCTAssertEqual(String(data: data.prefix(5), encoding: .ascii), "%PDF-")
        XCTAssertEqual(TerminationLetter.filename(for: contract),
                       "Résiliation EDF Entreprises - Boulangerie Martin.pdf")
    }

    func testThePreviewBookSavesAndDeletes() async throws {
        let repository = PreviewSignedContractsRepository(contracts: [])
        let model = await SignedContractsViewModel(repository: repository)
        var contract = SignedContract(clientName: "Nouveau")
        try await model.save(contract)
        contract.city = "Lille"
        try await model.save(contract)
        let saved = await model.contracts
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.city, "Lille")
        try await model.delete(contract)
        let remaining = try await repository.contracts()
        XCTAssertTrue(remaining.isEmpty)
    }
}
