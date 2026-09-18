import XCTest
import CryptoKit
@testable import EnergyCourtage

/// Exercises the real SupabaseClient against a real PostgREST.
///
/// Everything else in this suite tests decoders against handwritten JSON,
/// which proves the models parse something — not that the client asks for the
/// right thing, sends usable headers, or survives what the server actually
/// replies. These tests close that gap, and they are the only ones that would
/// notice a query parameter spelled wrong.
///
/// Skipped unless SUPABASE_TEST_URL is set, so the normal suite stays offline.
final class IntegrationTests: XCTestCase {

    private var client: SupabaseClient!
    private var baseURL: URL!

    private static let johann = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let pierre = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment

        // Skipping is right on a laptop with no server running, and wrong in
        // CI, where a skipped suite is indistinguishable from a passing one --
        // which is exactly how 12 of these reported success without making a
        // single request.
        if env["REQUIRE_INTEGRATION"] == "1" {
            XCTAssertNotNil(env["SUPABASE_TEST_URL"],
                            "REQUIRE_INTEGRATION is set but SUPABASE_TEST_URL is missing: "
                            + "the test process is not seeing its configuration")
            XCTAssertFalse((env["SUPABASE_TEST_JWT_SECRET"] ?? "").isEmpty,
                           "REQUIRE_INTEGRATION is set but no JWT secret reached the tests")
        }

        try XCTSkipUnless(env["SUPABASE_TEST_URL"] != nil,
                          "integration tests need a live PostgREST")
        baseURL = URL(string: env["SUPABASE_TEST_URL"]!)!
        // A bare PostgREST serves tables at the root, unlike hosted Supabase.
        client = SupabaseClient(baseURL: baseURL,
                                anonKey: token(for: nil, role: "anon"),
                                restPath: "", authPath: "")
    }

    /// PostgREST authenticates with a JWT signed by a shared secret, which is
    /// what Supabase issues too — so minting one here exercises exactly the
    /// header path the app uses in production.
    private func token(for subject: UUID?, role: String) -> String {
        let secret = ProcessInfo.processInfo.environment["SUPABASE_TEST_JWT_SECRET"] ?? ""
        func encode(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object,
                                                   options: [.sortedKeys])
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        var payload: [String: Any] = [
            "role": role,
            "exp": Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        ]
        if let subject { payload["sub"] = subject.uuidString.lowercased() }

        let signingInput = encode(["alg": "HS256", "typ": "JWT"]) + "." + encode(payload)
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        let encodedSignature = Data(signature).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return signingInput + "." + encodedSignature
    }

    private func signedIn(as user: UUID) async -> SupabaseClient {
        let authed = SupabaseClient(baseURL: baseURL,
                                    anonKey: token(for: nil, role: "anon"),
                                    restPath: "", authPath: "")
        await authed.setAccessToken(token(for: user, role: "authenticated"))
        return authed
    }

    // MARK: - The reads the list depends on

    func testPipelineComesBackInOrder() async throws {
        let repository = SupabaseRecommendationsRepository(client: await signedIn(as: Self.johann))
        let pipeline = try await repository.loadPipeline()

        XCTAssertEqual(pipeline.count, 5)
        XCTAssertEqual(pipeline.map(\.key),
                       ["a_contacter", "rdv_programme", "proposition_envoyee",
                        "devis_signe", "mission_terminee"])
        XCTAssertTrue(pipeline.first { $0.key == "devis_signe" }!.isRewardTrigger)
        // The templates are what the comment modal shows; an empty one would
        // render a blank dialog rather than fail.
        XCTAssertTrue(pipeline.allSatisfy { !($0.commentTemplate ?? "").isEmpty })
    }

    func testFirstPageDecodesEndToEnd() async throws {
        let repository = SupabaseRecommendationsRepository(client: await signedIn(as: Self.johann))
        let page = try await repository.loadPage(archived: false, search: "", cursor: nil)

        XCTAssertFalse(page.isEmpty, "the seed should give Johann something to look at")
        let reco = try XCTUnwrap(page.first { $0.filleulLastName == "Dubois" })
        XCTAssertEqual(reco.parrainName, "Johann Lefeuvre")
        XCTAssertFalse(reco.events.isEmpty, "the timeline comes back with the card")
    }

    /// The whole security model, asserted through the real wire rather than in
    /// the database where it is defined.
    func testAnotherApporteurSeesNothingOfHis() async throws {
        let marie = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let repository = SupabaseRecommendationsRepository(client: await signedIn(as: marie))
        let page = try await repository.loadPage(archived: false, search: "", cursor: nil)
        XCTAssertTrue(page.allSatisfy { $0.parrainName != "Johann Lefeuvre" })
    }

    func testSearchReachesTheServer() async throws {
        let repository = SupabaseRecommendationsRepository(client: await signedIn(as: Self.johann))
        let hits = try await repository.loadPage(archived: false, search: "Dubois", cursor: nil)
        XCTAssertFalse(hits.isEmpty)

        let misses = try await repository.loadPage(archived: false,
                                                   search: "zzz-no-such-person",
                                                   cursor: nil)
        XCTAssertTrue(misses.isEmpty)
    }

    func testDashboardStatsDecode() async throws {
        let profiles = SupabaseProfileRepository(client: await signedIn(as: Self.johann))
        let stats = try await profiles.dashboardStats()
        XCTAssertGreaterThanOrEqual(stats.activeCount, 1)
    }

    func testCurrentProfileComesBack() async throws {
        let profiles = SupabaseProfileRepository(client: await signedIn(as: Self.johann))
        let profile = try await profiles.currentProfile()
        XCTAssertEqual(profile.fullName, "Johann Lefeuvre")
        XCTAssertTrue(profile.canBeInvoiced, "the seed signs his mandate")
    }

    func testCatalogueLoads() async throws {
        let catalogue = SupabaseCatalogueRepository(client: await signedIn(as: Self.johann))
        let offers = try await catalogue.loadOffers()
        XCTAssertEqual(Set(offers.map(\.title)), ["Suivi", "Optimisation", "Conseil"])
        XCTAssertTrue(offers.allSatisfy { $0.priceLabel == "Sur devis" })
    }

    // MARK: - Writes

    func testCreatingARecommendationRoundTrips() async throws {
        let repository = SupabaseRecommendationsRepository(client: await signedIn(as: Self.johann))
        var draft = RecommendationDraft()
        draft.firstName = "Integration"
        draft.lastName = "Test\(Int.random(in: 1000...9999))"
        draft.phone = "06\(Int.random(in: 10_000_000...99_999_999))"
        draft.consentConfirmed = true

        let created = try await repository.create(draft)
        XCTAssertEqual(created.filleulFirstName, "Integration")
        // The entry stage is chosen by a trigger, so this proves the client can
        // omit it and still get a usable row back.
        XCTAssertNotNil(created.currentStageID)
        XCTAssertEqual(created.rewardStatus, .pending)
        XCTAssertNil(created.displayedAmount, "no figure before the reward triggers")
    }

    func testDuplicateDetectionAnswersAcrossFormatting() async throws {
        let repository = SupabaseRecommendationsRepository(client: await signedIn(as: Self.johann))
        // The seed stores Thomas Dubois as "+33 6 75 75 75 75".
        let check = try await repository.checkDuplicate(phone: "0675757575", email: "")
        XCTAssertTrue(check.alreadyYours)
        XCTAssertTrue(check.blocksSubmission)

        let clean = try await repository.checkDuplicate(phone: "0600000000", email: "")
        XCTAssertNil(clean.warning)
    }

    /// An apporteur calling an admin-only RPC must be refused by the server,
    /// and the client must turn that into something a person can read.
    func testAdminOnlyRPCIsRefusedWithAUsableMessage() async throws {
        let repository = SupabaseRecommendationsRepository(client: await signedIn(as: Self.johann))
        let page = try await repository.loadPage(archived: false, search: "", cursor: nil)
        let target = try XCTUnwrap(page.first)

        do {
            _ = try await repository.advanceStage(recommendationID: target.id,
                                                  stageKey: "devis_signe")
            XCTFail("an apporteur must not be able to advance a stage")
        } catch {
            let message = error.localizedDescription
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("42501"),
                           "a Postgres error code is not a message for a user")
        }
    }

    func testAdminCanAdvanceAndTheTemplateRenders() async throws {
        let admin = SupabaseRecommendationsRepository(client: await signedIn(as: Self.pierre))
        let page = try await admin.loadPage(archived: false, search: "Dubois", cursor: nil)
        let target = try XCTUnwrap(page.first)

        let updated = try await admin.advanceStage(recommendationID: target.id,
                                                   stageKey: "rdv_programme")
        let pipeline = try await admin.loadPipeline()
        let stage = try XCTUnwrap(pipeline.first { $0.key == "rdv_programme" })
        let event = try XCTUnwrap(updated.event(for: stage))
        XCTAssertTrue(event.comment?.contains("Thomas Dubois") == true,
                      "the stage template is rendered with the filleul's name")
    }

    func testPrivateNotesRoundTrip() async throws {
        let repository = SupabaseRecommendationsRepository(client: await signedIn(as: Self.johann))
        let page = try await repository.loadPage(archived: false, search: "", cursor: nil)
        let target = try XCTUnwrap(page.first)

        try await repository.saveNote(recommendationID: target.id, body: "Rappeler lundi")
        let read = try await repository.note(recommendationID: target.id)
        XCTAssertEqual(read, "Rappeler lundi")

        // written twice: the upsert must replace, not accumulate
        try await repository.saveNote(recommendationID: target.id, body: "Rappeler mardi")
        // hoisted out of the assertion: XCTAssert takes an autoclosure, which
        // cannot contain an await
        let rewritten = try await repository.note(recommendationID: target.id)
        XCTAssertEqual(rewritten, "Rappeler mardi")
    }
}
