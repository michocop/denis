import XCTest
@testable import EnergyCourtage

/// The apporteur's first sign-in: status, details, the contract read to the
/// end, one SMS code, and the contract on file.
final class OnboardingTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await DemoContractStore.shared.reset()
        await DemoProfileStore.shared.reset()
        await DemoLegalStore.shared.reset()
    }

    @MainActor
    private func makeModel() -> OnboardingModel {
        OnboardingModel(profiles: PreviewProfileRepository(), legal: PreviewLegalRepository(),
                        sms: PreviewSmsRepository(required: true), contracts: PreviewContractRepository())
    }

    @MainActor
    func testAnApporteurSignsTheirContractWithOneSmsCode() async throws {
        let profiles = PreviewProfileRepository()
        let before = try await profiles.currentProfile()
        XCTAssertFalse(before.hasSignedContract, "a new apporteur starts with the onboarding")

        let model = makeModel()
        await model.load()
        XCTAssertNotNil(model.contract, "the contract is published")
        XCTAssertNotNil(model.mandate, "with the mandate it annexes")

        model.choose(.independant)
        XCTAssertEqual(model.draft?.legalForm, "Particulier", "the form the server stores for a particulier")
        XCTAssertNil(model.draft?.companyName, "a particulier invoices in their own name")
        XCTAssertEqual(model.statusSummary, "Indépendant · Particulier")
        model.next()
        XCTAssertEqual(model.step, .details)

        XCTAssertEqual(model.detailsProblem, "Indiquez l'adresse.", "no SIRET asked for: the address comes first")
        model.draft?.address = "3 rue Nationale"
        model.draft?.postalCode = "59000"
        model.draft?.city = "Lille"
        XCTAssertNil(model.detailsProblem)
        await model.saveDetails()
        XCTAssertEqual(model.step, .contract)
        XCTAssertNil(model.draft?.siret)

        await model.startSigning()
        XCTAssertEqual(model.signingStep, .enterPhone, "no verified mobile yet: the number comes first")
        let challenge = try await model.requestCode(phone: "06 12 34 56 78", resend: false)
        XCTAssertTrue(challenge.required)
        let wrong = try await model.confirmCode("000000")
        XCTAssertFalse(wrong.ok, "a wrong code signs nothing")
        let right = try await model.confirmCode(PreviewSmsRepository.demoCode)
        XCTAssertTrue(right.ok)
        await model.codeConfirmed()

        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(model.signed?.businessStatus, .independant)
        XCTAssertEqual(model.signatures, 1, "answered with the success vibration")
        let after = try await profiles.currentProfile()
        XCTAssertTrue(after.hasSignedContract, "the onboarding is not shown again")
        XCTAssertTrue(after.canBeInvoiced, "and the mandate, signed with it, lets invoices be issued")
        XCTAssertEqual(after.address, "3 rue Nationale", "the profile shows what was typed")
        XCTAssertNil(after.siret, "and no SIRET")
    }

    @MainActor
    func testAParticulierKeepsNothingOfACompany() async {
        let model = makeModel()
        await model.load()
        model.choose(.societe)
        model.draft?.siret = "12345678900012"
        model.draft?.companyName = "Lefeuvre Conseil"
        model.choose(.independant)
        XCTAssertNil(model.draft?.siret, "a particulier has no SIRET")
        XCTAssertNil(model.draft?.companyName)
        XCTAssertEqual(model.draft?.legalForm, "Particulier")
        model.choose(.societe)
        XCTAssertEqual(model.draft?.legalForm, "SASU", "\"Particulier\" is no company's form")
    }

    @MainActor
    func testACompanyStillNeedsItsSiret() async {
        let model = makeModel()
        await model.load()
        model.choose(.societe)
        model.draft?.companyName = "Lefeuvre Conseil"
        model.draft?.siret = "123 456"
        model.draft?.address = "1 rue"
        model.draft?.postalCode = "59000"
        model.draft?.city = "Lille"
        XCTAssertEqual(model.detailsProblem, "Le SIRET compte 14 chiffres.")
        model.draft?.siret = "123 456 789 00012"
        XCTAssertNil(model.detailsProblem)
        await model.saveDetails()
        XCTAssertEqual(model.draft?.siret, "12345678900012", "stored as digits")
    }

    @MainActor
    func testAMicroEntrepreneurTradesUnderTheirOwnName() async {
        let model = makeModel()
        await model.load()
        model.choose(.societe)
        model.draft?.legalForm = "Micro-entrepreneur"
        model.draft?.companyName = nil
        model.draft?.siret = "12345678900012"
        model.draft?.address = "1 rue"
        model.draft?.postalCode = "59000"
        model.draft?.city = "Lille"
        XCTAssertTrue(model.companyNameIsOptional)
        XCTAssertNil(model.detailsProblem, "no company name needed")
        XCTAssertEqual(model.statusSummary, "Société ou entreprise · Micro-entrepreneur")
        model.draft?.legalForm = "Entreprise individuelle"
        XCTAssertNil(model.detailsProblem)
        model.draft?.legalForm = "EURL"
        XCTAssertEqual(model.detailsProblem, "Indiquez la raison sociale.")
    }

    // MARK: - The particulier's ceiling

    func testTheCeilingCardSpeaksFromTheAlertOn() throws {
        let cap = try SupabaseClient.decoder.decode(CommissionCap.self, from: Data("""
        {"particulier":true,"year":2026,"total":1800.00,"cap":2400.00,"alert_from":1800.00}
        """.utf8))
        XCTAssertEqual(cap.alert, .approaching, "from 1 800 €")
        XCTAssertEqual(cap.title, "Plafond de 2\u{00A0}400\u{00A0}€ par an")
        XCTAssertEqual(cap.message, "Vous avez reçu 1\u{00A0}800\u{00A0}€ de commissions en 2026. Au-delà de 2\u{00A0}400\u{00A0}€ par année civile, vous devez exercer en société ou en micro-entreprise et renseigner votre SIRET.")

        XCTAssertNil(CommissionCap(particulier: true, year: 2026, total: 1799.99).alert, "below it, nothing")
        XCTAssertNil(CommissionCap(particulier: false, year: 2026, total: 5000).alert, "nor with a SIRET")

        let close = CommissionCap(particulier: true, year: 2026, total: Decimal(string: "2399.60")!)
        XCTAssertEqual(close.alert, .approaching)
        XCTAssertTrue(close.message.hasPrefix("Vous avez reçu 2\u{00A0}399,60\u{00A0}€"),
                      "cents kept: rounded, it would read as the ceiling")

        let reached = CommissionCap(particulier: true, year: 2026, total: 2400)
        XCTAssertEqual(reached.alert, .reached)
        XCTAssertEqual(reached.title, "Plafond atteint")
        XCTAssertEqual(reached.message, "Vos commissions de 2026 ont atteint 2\u{00A0}400\u{00A0}€. Pour recevoir les suivantes, renseignez votre SIRET (société ou micro-entreprise).")
    }

    @MainActor
    func testAccueilWarnsAnApporteurOnly() async {
        struct Capped: CommissionsRepository {
            func statement(year: Int?) async throws -> [CommissionLine] { [] }
            func commissionCap() async throws -> CommissionCap {
                CommissionCap(particulier: true, year: 2026, total: 2000)
            }
        }
        let apporteur = HomeViewModel(profiles: PreviewProfileRepository(), commissions: Capped())
        await apporteur.load()
        XCTAssertEqual(apporteur.capAlert?.alert, .approaching)

        let admin = HomeViewModel(profiles: PreviewProfileRepository(role: .admin), commissions: Capped())
        await admin.load()
        XCTAssertNil(admin.capAlert, "the company has no ceiling")

        let demo = HomeViewModel(profiles: PreviewProfileRepository(), commissions: PreviewCommissionsRepository())
        await demo.load()
        XCTAssertNil(demo.capAlert, "the demo's 1 300 € say nothing")
    }

    @MainActor
    func testACompanyNeedsItsNameBeforeGoingOn() async {
        let model = makeModel()
        await model.load()
        model.choose(.societe)
        model.draft?.companyName = " "
        model.draft?.siret = "12345678900012"
        model.draft?.address = "1 rue"
        model.draft?.postalCode = "59000"
        model.draft?.city = "Lille"
        XCTAssertEqual(model.detailsProblem, "Indiquez la raison sociale.")
        XCTAssertEqual(model.draft?.legalForm, "SASU")
    }

    func testAContractAndAMemberLineDecodeFromTheServer() throws {
        let contract = try SupabaseClient.decoder.decode(ApporteurContract.self, from: Data("""
        {"id":"5f0c2a1e-8b7d-4c3a-9e21-0d6f4b8a7c11","profile_id":"11111111-1111-1111-1111-111111111111",
         "signed_at":"2026-10-14T14:07:31.123+00:00","business_status":"societe",
         "contract_version":"2026-10-1","contract_sha256":"aa","mandate_version":"2026-10-1",
         "mandate_sha256":"bb","signer_full_name":"Lina Laurent","email":"lina@example.test",
         "company_name":"Laurent Conseil","legal_form":"SASU","siret":"12345678900012",
         "address":"3 rue Nationale","postal_code":"59000","city":"Lille","otp_verified":true,
         "otp_phone":"+33 6 •• •• •• 32","ip_address":null,"user_agent":null,"pdf_path":null,"pdf_sha256":null}
        """.utf8))
        XCTAssertEqual(contract.reference, "CT-5F0C2A1E")
        XCTAssertEqual(contract.businessStatus, .societe)
        XCTAssertNil(contract.pdfPath, "the PDF follows a few seconds later")

        let member = try SupabaseClient.decoder.decode(MemberOverview.self, from: Data("""
        {"id":"11111111-1111-1111-1111-111111111111","full_name":"Lina Laurent","email":"lina@example.test",
         "phone":null,"role":"apporteur","status":"active","vat_liable":false,"has_mandate":true,
         "bank_details_on_file":false,"created_at":"2026-10-14T14:00:00+00:00","business_status":"societe",
         "contract_id":"5f0c2a1e-8b7d-4c3a-9e21-0d6f4b8a7c11","contract_signed_at":"2026-10-14T14:07:31+00:00",
         "contract_pdf_ready":true,"total_recommendations":0,"active_recommendations":0,
         "paid_total":0,"owed_total":0,"last_recommendation_at":null}
        """.utf8))
        XCTAssertNotNil(member.contractSignedAt)
        XCTAssertEqual(member.contractPdfReady, true)
        XCTAssertEqual(member.businessStatus, .societe)
    }

    @MainActor
    func testTheDemoContractOpensAsAPDF() async throws {
        let contracts = PreviewContractRepository()
        let signed = try await contracts.sign(status: .societe, contractSHA256: "", mandateSHA256: "")
        let pdf = try await contracts.pdf(of: signed)
        let data = try XCTUnwrap(pdf)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
    }
}
