import XCTest
@testable import EnergyCourtage

final class RewardStageTests: XCTestCase {

    func testAmountsAreReadTheFrenchWayAndTheEnglishWay() {
        XCTAssertEqual(RewardLineDraft.parse("1 300,50"), Decimal(string: "1300.5"))
        XCTAssertEqual(RewardLineDraft.parse("1300.5"), Decimal(string: "1300.5"))
        XCTAssertEqual(RewardLineDraft.parse("1\u{202F}300"), 1300)
        XCTAssertNil(RewardLineDraft.parse("-5"))
        XCTAssertNil(RewardLineDraft.parse("12,345"), "three decimals is a typo, not cents")
        XCTAssertNil(RewardLineDraft.parse("abc"))
        XCTAssertNil(RewardLineDraft.parse(""))
    }

    func testOnlyTickedServicesCountTowardsTheTotals() {
        let form = RewardStageForm(lines: [
            RewardLineDraft(label: "Mandat de vente", turnover: 1_300_000, reward: 1300, signed: true),
            RewardLineDraft(label: "Étude de financement", turnover: 2000, reward: 150, signed: false)
        ])
        XCTAssertEqual(form.turnoverTotal, 1_300_000)
        XCTAssertEqual(form.rewardTotal, 1300)
        XCTAssertNil(form.problem)
    }

    func testTheCeilingIsEnforcedBeforeTheServerIsAsked() {
        let form = RewardStageForm(lines: [
            RewardLineDraft(label: "A", turnover: 10, reward: 1500),
            RewardLineDraft(label: "B", turnover: 10, reward: 600)
        ], maxReward: 2000)
        XCTAssertEqual(form.rewardTotal, 2100)
        XCTAssertNotNil(form.problem)
    }

    func testAServiceNeedsANameAndSomethingSigned() {
        var form = RewardStageForm()
        XCTAssertEqual(form.problem, "Ajoutez au moins une prestation.")

        form.lines = [RewardLineDraft(label: "", turnover: 10, reward: 100)]
        XCTAssertEqual(form.problem, "Prestation 1 : indiquez l'intitulé.")

        form.lines = [RewardLineDraft(label: "A", turnover: 10, reward: 100, signed: false)]
        XCTAssertNotNil(form.problem)

        form.lines = [RewardLineDraft(label: "A", turnover: 10, reward: 100), RewardLineDraft()]
        XCTAssertNil(form.problem, "an empty row left at the end is ignored")
        XCTAssertEqual(form.submittedLines.count, 1)
    }

    func testAMistypedAmountIsCaughtRatherThanReadAsZero() {
        var line = RewardLineDraft(label: "A", reward: 100)
        line.turnoverText = "12a"
        let form = RewardStageForm(lines: [line])
        XCTAssertEqual(form.problem, "Prestation 1 : montant invalide.")
    }

    func testTheCommentScreenOpensOnTheStageWordingFilledIn() {
        let reco = Recommendation(id: UUID(), filleulFirstName: "Thomas", filleulLastName: "Dubois",
                                  parrainName: "Johann Lefeuvre", createdAt: .now,
                                  currentStageID: UUID())
        let text = StageCommentTemplate.render(
            "Bonjour {parrain}, j'ai contacté {filleul}.", for: reco)
        XCTAssertEqual(text, "Bonjour Johann, j'ai contacté Thomas Dubois.")
        XCTAssertEqual(StageCommentTemplate.render(nil, for: reco), "")
    }

    func testPayoutMethodsMatchTheDatabaseEnum() {
        XCTAssertEqual(PayoutMethod.allCases.map(\.rawValue),
                       ["virement", "cheque", "carte_cadeau", "avoir_facture"])
        XCTAssertEqual(PayoutMethod.carteCadeau.label, "Carte cadeau")
    }

    @MainActor
    func testTheDemoSignatureAsksForACodeAndOnlyTheRightOneSigns() async {
        let model = InvoiceViewModel(invoiceID: UUID(), repository: PreviewInvoiceRepository())
        await model.load()
        await model.sign()
        XCTAssertEqual(model.codePrompt?.sentTo, "06 •• •• •• 78")

        await model.submitCode("000000")
        XCTAssertNotNil(model.codeError)
        XCTAssertNotNil(model.codePrompt, "a wrong code keeps the sheet up")

        await model.submitCode("123456")
        XCTAssertNil(model.codePrompt, "the right code signs and closes the sheet")
    }
}
