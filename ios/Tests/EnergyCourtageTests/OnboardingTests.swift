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
        XCTAssertEqual(model.draft?.legalForm, "Micro-entrepreneur", "the first form of the status is preselected")
        XCTAssertNil(model.draft?.companyName, "an independent invoices in their own name")
        model.next()
        XCTAssertEqual(model.step, .details)

        model.draft?.siret = "123 456"
        XCTAssertEqual(model.detailsProblem, "Le SIRET compte 14 chiffres.")
        model.draft?.siret = "123 456 789 00012"
        model.draft?.address = "3 rue Nationale"
        model.draft?.postalCode = "59000"
        model.draft?.city = "Lille"
        XCTAssertNil(model.detailsProblem)
        await model.saveDetails()
        XCTAssertEqual(model.step, .contract)
        XCTAssertEqual(model.draft?.siret, "12345678900012", "stored as digits")

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
        XCTAssertEqual(after.siret, "12345678900012", "the profile shows what was typed")
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
