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

    // MARK: - Messaging

    /// The chat list read from `threads` for a long time, which has no name on
    /// a direct conversation, no last message and no unread count -- so every
    /// row said "Conversation / Aucun message" and the decoder was perfectly
    /// happy. Only a real round trip catches that.
    func testAConversationComesBackWithSomethingToShow() async throws {
        let johann = SupabaseChatRepository(client: await signedIn(as: Self.johann))
        let pierre = SupabaseChatRepository(client: await signedIn(as: Self.pierre))

        let threadID = try await johann.startSupportThread()
        _ = try await johann.send(body: "Une question sur Thomas Dubois.", threadID: threadID)
        // Read first, so the count below is about this test's message and not
        // whatever an earlier test left in the same conversation. These run
        // against one database, in one order, and a test that only passes
        // first is worse than no test.
        try await johann.markRead(threadID: threadID)
        _ = try await pierre.send(body: "Je vous réponds tout de suite.", threadID: threadID)

        let mine = try await johann.loadThreads()
        let row = try XCTUnwrap(mine.first { $0.id == threadID })
        XCTAssertEqual(row.counterpartName, "Pierre-Louis Tettamanti",
                       "a direct conversation is named after the other person")
        XCTAssertEqual(row.lastMessage, "Je vous réponds tout de suite.")
        XCTAssertEqual(row.unreadCount, 1, "and counts only what I have not read")

        // The name has to survive: an apporteur can read only their own row in
        // profiles, so a naive join would drop every message an admin sent.
        let messages = try await johann.loadMessages(threadID: threadID)
        XCTAssertEqual(messages.last?.senderName, "Pierre-Louis Tettamanti")

        try await johann.markRead(threadID: threadID)
        let cleared = try await johann.loadThreads()
        XCTAssertEqual(cleared.first { $0.id == threadID }?.unreadCount, 0)

        // pinning is per reader, not per thread
        try await johann.setFlags(threadID: threadID, pinned: true, archived: nil)
        let pinned = try await johann.loadThreads()
        XCTAssertTrue(pinned.first { $0.id == threadID }?.pinned == true)
        let theirs = try await pierre.loadThreads()
        XCTAssertFalse(theirs.first { $0.id == threadID }?.pinned == true)

        // and starting the conversation again must reuse it
        let again = try await johann.startSupportThread()
        XCTAssertEqual(again, threadID)
    }

    // MARK: - Notifications

    func testAMessageNotifiesTheOtherSideAndNotTheSender() async throws {
        let johann = SupabaseChatRepository(client: await signedIn(as: Self.johann))
        let pierre = SupabaseChatRepository(client: await signedIn(as: Self.pierre))
        let inbox = SupabaseNotificationsRepository(client: await signedIn(as: Self.johann))

        let threadID = try await johann.startSupportThread()
        _ = try await pierre.send(body: "Pouvez-vous rappeler Thomas Dubois ?",
                                  threadID: threadID)

        let items = try await inbox.notifications()
        let arrived = try XCTUnwrap(items.first { $0.kind == "message_received" })
        XCTAssertEqual(arrived.title, "Pierre-Louis Tettamanti")
        XCTAssertEqual(arrived.body, "Pouvez-vous rappeler Thomas Dubois ?")
        XCTAssertEqual(arrived.threadId, threadID,
                       "so tapping it can open the conversation it is about")

        let before = try await inbox.unreadCount()
        XCTAssertGreaterThan(before, 0)
        try await inbox.markAllRead()
        let after = try await inbox.unreadCount()
        XCTAssertEqual(after, 0)

        // writing to yourself notifies nobody
        _ = try await johann.send(body: "Je le rappelle cet après-midi.", threadID: threadID)
        let mine = try await inbox.notifications()
        XCTAssertFalse(mine.contains { $0.title == "Johann Lefeuvre" },
                       "nobody is notified of their own message")
    }

    // MARK: - Identity

    /// The bug this pins: the client used to work out who it was by reading
    /// `profiles` with `limit 1`. RLS narrows that to one row for an
    /// apporteur and not for an admin, who can read everyone — so an admin
    /// got back whichever row came first. It showed them someone else's
    /// profile, and stamped the wrong sender on a message, which RLS
    /// refused. That refusal is the only reason it was ever noticed.
    func testAnAdminIsToldWhoTheyAreAndNotWhoIsFirst() async throws {
        let client = await signedIn(as: Self.pierre)
        let profiles = SupabaseProfileRepository(client: client)

        let me = try await profiles.currentProfile()
        XCTAssertEqual(me.id, Self.pierre)
        XCTAssertEqual(me.firstName, "Pierre-Louis")
        XCTAssertTrue(me.role.isAdmin)

        // and the precondition that made the old shape unsound
        struct Row: Decodable { let id: UUID }
        let everyone: [Row] = try await client.get("profiles",
                                                   query: [URLQueryItem(name: "select", value: "id")])
        XCTAssertGreaterThan(everyone.count, 1,
                             "an admin reads more than one profile, so the first is not an identity")
    }

    func testAnApporteurIsToldWhoTheyAre() async throws {
        let profiles = SupabaseProfileRepository(client: await signedIn(as: Self.johann))
        let me = try await profiles.currentProfile()
        XCTAssertEqual(me.id, Self.johann)
        XCTAssertFalse(me.role.isAdmin)
    }

    func testRegisteringTheSameDeviceTwiceIsNotAnError() async throws {
        let inbox = SupabaseNotificationsRepository(client: await signedIn(as: Self.johann))
        try await inbox.register(deviceToken: "integration-token")
        try await inbox.register(deviceToken: "integration-token")
    }
}
