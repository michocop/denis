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
        XCTAssertEqual((json["delivery_points"] as? [Any])?.count, 0)
    }

    func testARowFromTheServerDecodes() throws {
        let row = """
        [{"id":"7d1f0c1e-4c6b-4d8e-9a0b-1c2d3e4f5a6b","created_by":null,
          "client_kind":"particulier","client_name":"Thomas Dubois",
          "delivery_points":[{"id":"0a1b2c3d-0000-4000-8000-000000000001","energy":"gaz","number":"GI123","label":"Maison"},
                             {"energy":"electricite","number":"14523698741230"}],
          "signed_contract_files":[{"count":2}],
          "ends_on":"2027-06-30","termination_on":null,
          "previous_supplier_address":"TSA 1\\n75000 Paris",
          "created_at":"2026-11-16T10:00:00.123+00:00","updated_at":"2026-11-16T10:00:00+00:00"}]
        """
        let rows = try SupabaseClient.decoder.decode([SignedContract].self, from: Data(row.utf8))
        XCTAssertEqual(rows.first?.clientKind, .particulier)
        XCTAssertEqual(rows.first?.deliveryPoints.map(\.number), ["GI123", "14523698741230"])
        XCTAssertEqual(rows.first?.deliveryPoints.first?.label, "Maison")
        XCTAssertEqual(rows.first?.energies, [.electricite, .gaz])
        XCTAssertEqual(rows.first?.fileCount, 2)
        XCTAssertEqual(rows.first?.endsOn, "2027-06-30")
        XCTAssertEqual(rows.first?.previousSupplierAddress, "TSA 1\n75000 Paris")
    }

    func testACompanyLetterSpeaksForTheCompany() {
        let contract = SignedContract(
            clientKind: .professionnel, clientName: "Boulangerie Martin",
            signatoryName: "Sophie Martin", signatoryTitle: "Gérante", siret: "81234567800012",
            address: "4 place du Marché", postalCode: "59000", city: "Lille",
            deliveryPoints: [DeliveryPoint(energy: .electricite, number: "14523698741230")],
            previousSupplier: "EDF Entreprises",
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
                                      deliveryPoints: [DeliveryPoint(energy: .gaz, number: "GI123")],
                                      previousSupplier: "Engie")
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
        XCTAssertGreaterThan(data.count, 1000)
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

    func testALetterListsEveryMeter() {
        let contract = SignedContract(
            clientName: "Multi-sites", address: "1 rue A", postalCode: "59000", city: "Lille",
            deliveryPoints: [
                DeliveryPoint(energy: .electricite, number: "14523698741230", label: "Siège"),
                DeliveryPoint(energy: .electricite, number: "14523698741231", site: "2 rue B, 59000 Lille"),
                DeliveryPoint(energy: .gaz, number: "GI123456"),
                DeliveryPoint(energy: .gaz, number: "   "),
            ],
            previousSupplier: "EDF")
        let letter = TerminationLetter(contract: contract, on: now)
        XCTAssertEqual(letter.subject, "Objet : Résiliation du contrat de fourniture d'électricité et de gaz naturel")
        XCTAssertTrue(letter.references.contains("PDL/PRM : 14523698741230 (Siège)"))
        XCTAssertTrue(letter.references.contains("PDL/PRM : 14523698741231 – 2 rue B, 59000 Lille"))
        XCTAssertTrue(letter.references.contains("PCE : GI123456"))
        XCTAssertFalse(letter.references.contains { $0.hasPrefix("Adresse d") },
                       "a site is given, so the client's address is not repeated as the site")
        XCTAssertTrue(letter.paragraphs.joined().contains("pour les points de livraison référencés ci-dessus"))
        XCTAssertEqual(contract.filledPoints.count, 3)
    }

    func testPastedNumbersBecomePoints() {
        let points = DeliveryPoint.parse("14523698741230\n 14523698741231 ,\n\nGI 123;  ", energy: .gaz)
        XCTAssertEqual(points.map(\.number), ["14523698741230", "14523698741231", "GI 123"])
        XCTAssertTrue(points.allSatisfy { $0.energy == .gaz })
    }

    func testOnlyFilledPointsAreSent() throws {
        let contract = SignedContract(clientName: "X", deliveryPoints: [
            DeliveryPoint(energy: .gaz, number: " GI1 ", label: "  ", site: "Rue"),
            DeliveryPoint(energy: .electricite, number: ""),
        ])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SupabaseSignedContractsRepository.values(of: contract))) as! [String: Any]
        let points = json["delivery_points"] as! [[String: Any]]
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0]["number"] as? String, "GI1")
        XCTAssertEqual(points[0]["energy"] as? String, "gaz")
        XCTAssertNil(points[0]["label"])
        XCTAssertEqual(points[0]["site"] as? String, "Rue")
    }

    func testSearchFindsAMeterHoweverItIsSpaced() {
        let contract = SignedContract(clientName: "Boulangerie Martin", city: "Lille",
                                      deliveryPoints: [DeliveryPoint(number: "14 52 36 98 74 12 30")],
                                      newSupplier: "Ekwateur")
        XCTAssertTrue(contract.matches("14523698"))
        XCTAssertTrue(contract.matches("boulangerie lille"))
        XCTAssertTrue(contract.matches("ekwa"))
        XCTAssertFalse(contract.matches("engie"))
        XCTAssertTrue(contract.matches("  "))
    }

    func testDuplicateKeepsTheClientNotTheDeal() {
        let original = PreviewSignedContractsRepository.samples(now: now)[0]
        let copy = original.duplicate()
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.clientName, original.clientName)
        XCTAssertEqual(copy.deliveryPoints.map(\.number), original.deliveryPoints.map(\.number))
        XCTAssertNotEqual(copy.deliveryPoints.first?.id, original.deliveryPoints.first?.id)
        XCTAssertNil(copy.previousSupplier)
        XCTAssertNil(copy.endsOn)
    }

    func testFilesAreFiledAndRemoved() async throws {
        let repository = PreviewSignedContractsRepository(contracts: [SignedContract(clientName: "A")])
        let id = try await repository.contracts()[0].id
        let file = try await repository.addFile(
            DocumentUpload(data: Data("%PDF-1.4".utf8), filename: "Contrat.pdf", mimeType: "application/pdf"),
            to: id)
        let names = try await repository.files(contractID: id).map(\.filename)
        XCTAssertEqual(names, ["Contrat.pdf"])
        let count = try await repository.contracts()[0].fileCount
        XCTAssertEqual(count, 1)
        try await repository.removeFile(file)
        let left = try await repository.files(contractID: id)
        XCTAssertTrue(left.isEmpty)
        await XCTAssertThrowsAsync(try await repository.addFile(
            DocumentUpload(data: Data(count: DocumentUpload.maxBytes + 1), filename: "big.pdf",
                           mimeType: "application/pdf"), to: id))
    }
}

private func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T,
                                     file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
