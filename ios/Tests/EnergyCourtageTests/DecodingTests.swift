import XCTest
@testable import EnergyCourtage

/// These decode the exact JSON the database emits. They exist because the
/// decoder applies `.convertFromSnakeCase`, which silently stops matching the
/// moment a model declares a snake_case CodingKey — a failure that produces an
/// empty screen rather than an error anyone would notice in review.
final class DecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try SupabaseClient.decoder.decode(type, from: Data(json.utf8))
    }

    func testInvoiceDocumentMatchesTheDatabaseShape() throws {
        let json = """
        {
          "number": "FA-2026-0001",
          "document_sha256": "8f434346648f6b96df89dda901c5176b10a6d83961dd3c1ac88b59b2dc327aa4",
          "issuer": { "name": "Pierre-Louis Tettamanti", "company": "Trinity Énergie",
                      "city": "AIX-EN-PEVELE" },
          "apporteur": { "name": "Johann Lefeuvre", "company": "Lefeuvre Conseil",
                         "siret": "12345678900011" },
          "attestation": { "soussigne": "Johann Lefeuvre",
                           "mis_en_relation": "Trinity Énergie",
                           "avec": "Thomas Dubois",
                           "prestation": "Apport d'affaires - mise en relation",
                           "intervenue_le": "17.09.2026" },
          "amount": { "ht": "300.00", "vat_rate": 0, "vat": "0.00",
                      "ttc": "300.00", "currency": "EUR" },
          "legal_mentions": "TVA non applicable – Article 293B du CGI",
          "payment_method": "Virement bancaire",
          "place": "AIX-EN-PEVELE",
          "issued_on": "17.09.2026",
          "tax_notice": "… CERFA 2042 C -",
          "status": "awaiting_signatures",
          "signatures": [
            { "role": "apporteur", "name": "Johann Lefeuvre", "signed": true,
              "signed_at": "2026-09-17T14:57:00+00:00" },
            { "role": "entreprise", "name": "Pierre-Louis Tettamanti", "signed": false,
              "signed_at": null }
          ]
        }
        """
        let document = try decode(InvoiceDocument.self, json)

        XCTAssertEqual(document.number, "FA-2026-0001")
        XCTAssertEqual(document.documentSha256?.count, 64)
        XCTAssertEqual(document.attestation.avec, "Thomas Dubois")
        XCTAssertEqual(document.attestation.misEnRelation, "Trinity Énergie")
        XCTAssertEqual(document.amount.ttc, "300.00")
        XCTAssertEqual(document.legalMentions, "TVA non applicable – Article 293B du CGI")
        XCTAssertEqual(document.signatures.count, 2)
        XCTAssertEqual(document.signatures[0].label, "Signature de l'apporteur")
        XCTAssertNotNil(document.signatures[0].signedAt)
        XCTAssertFalse(document.isFullySigned)
    }

    func testDashboardStatsMatchTheRPCShape() throws {
        let stats = try decode(DashboardStats.self, """
        { "active_count": 3, "archived_count": 1, "pending_total": 0,
          "earned_total": 1000, "paid_total": 0, "conversion_rate": 25.0 }
        """)
        XCTAssertEqual(stats.activeCount, 3)
        XCTAssertEqual(stats.earnedTotal, 1000)
        XCTAssertEqual(stats.conversionRate, 25.0, accuracy: 0.001)
    }

    func testProfileDecodesTheBillingMandate() throws {
        let profile = try decode(Profile.self, """
        { "id": "11111111-1111-1111-1111-111111111111", "role": "apporteur",
          "first_name": "Johann", "last_name": "Lefeuvre", "email": "j@x.test",
          "vat_liable": false, "billing_mandate_signed_at": "2026-01-05T10:00:00+00:00" }
        """)
        XCTAssertEqual(profile.fullName, "Johann Lefeuvre")
        XCTAssertEqual(profile.initials, "JL")
        XCTAssertTrue(profile.canBeInvoiced)
    }

    /// Without a mandate no invoice can be issued at all, so the app has to
    /// know before the apporteur expects to be paid.
    func testProfileWithoutMandateCannotBeInvoiced() throws {
        let profile = try decode(Profile.self, """
        { "id": "22222222-2222-2222-2222-222222222222", "role": "apporteur",
          "first_name": "Marie", "last_name": "Durand", "email": "m@x.test",
          "vat_liable": false, "billing_mandate_signed_at": null }
        """)
        XCTAssertFalse(profile.canBeInvoiced)
    }

    func testOfferPricing() throws {
        let offer = try decode(Offer.self, """
        { "id": "33333333-3333-3333-3333-333333333333", "title": "Suivi",
          "description": "Nous surveillons vos dates d'échéances",
          "category": "Energie", "price_mode": "quote", "price": null,
          "availability_label": "Disponible", "is_active": true, "position": 1 }
        """)
        XCTAssertEqual(offer.priceLabel, "Sur devis")
        XCTAssertEqual(offer.availabilityLabel, "Disponible")
    }
}

final class FormAndFilterTests: XCTestCase {

    /// The consent box is a legal prerequisite, so the form is invalid without
    /// it however complete the rest is.
    func testDraftIsInvalidWithoutConsent() {
        var draft = RecommendationDraft()
        draft.firstName = "Thomas"
        draft.lastName = "Dubois"
        draft.phone = "+33 6 75 75 75 75"
        XCTAssertFalse(draft.isValid)

        draft.consentConfirmed = true
        XCTAssertTrue(draft.isValid)
    }

    func testDraftRequiresAName() {
        var draft = RecommendationDraft()
        draft.consentConfirmed = true
        draft.phone = "+33 6 00 00 00 00"
        draft.firstName = "   "
        draft.lastName = "Dubois"
        XCTAssertFalse(draft.isValid)
    }

    func testTicketsAndDiscussionsAreSeparateTabs() {
        let model = ChatViewModel(repository: StubChatRepository())
        let direct = ChatThread(id: UUID(), kind: .direct, counterpartName: "Johann Lefeuvre")
        let ticket = ChatThread(id: UUID(), kind: .ticket, title: "Problème de virement",
                                counterpartName: "Support")
        model.injectForTesting([direct, ticket])

        model.tab = .discussions
        XCTAssertEqual(model.visibleThreads.map(\.id), [direct.id])

        model.tab = .tickets
        XCTAssertEqual(model.visibleThreads.map(\.id), [ticket.id])
    }

    func testPinnedConversationsSortFirst() {
        let model = ChatViewModel(repository: StubChatRepository())
        let recent = ChatThread(id: UUID(), kind: .direct, counterpartName: "Récent",
                                lastMessageAt: .now)
        let pinned = ChatThread(id: UUID(), kind: .direct, counterpartName: "Épinglé",
                                lastMessageAt: .now.addingTimeInterval(-86_400), pinned: true)
        model.injectForTesting([recent, pinned])
        XCTAssertEqual(model.visibleThreads.first?.id, pinned.id)
    }
}

struct StubChatRepository: ChatRepository {
    func loadThreads() async throws -> [ChatThread] { [] }
    func loadMessages(threadID: UUID) async throws -> [ChatMessage] { [] }
    func send(body: String, threadID: UUID) async throws -> ChatMessage {
        ChatMessage(id: UUID(), threadID: threadID, senderID: UUID(),
                    senderName: "", body: body, createdAt: .now)
    }
    func markRead(threadID: UUID) async throws {}
    func openTicket(subject: String, body: String) async throws -> UUID { UUID() }
}

/// Auth routing is driven entirely by `my_account_state()`, so its shape is
/// worth pinning: a decode failure here would drop every user back to the
/// sign-in screen with no error to explain why.
final class AccountStateTests: XCTestCase {

    private struct AccountState: Decodable {
        let state: String
        let role: UserRole?
        let fullName: String?
    }

    private func decode(_ json: String) throws -> AccountState {
        try SupabaseClient.decoder.decode(AccountState.self, from: Data(json.utf8))
    }

    func testReadyAccount() throws {
        let account = try decode("""
        { "state": "ready", "role": "admin", "full_name": "Pierre-Louis Tettamanti" }
        """)
        XCTAssertEqual(account.state, "ready")
        XCTAssertEqual(account.role, .admin)
        XCTAssertTrue(account.role?.isAdmin == true)
        XCTAssertEqual(account.fullName, "Pierre-Louis Tettamanti")
    }

    func testStatesWithoutAProfileCarryNoRole() throws {
        for state in ["needs_invite", "signed_out"] {
            let account = try decode("{ \"state\": \"\(state)\" }")
            XCTAssertEqual(account.state, state)
            XCTAssertNil(account.role)
        }
    }

    func testPendingAndSuspendedAreDistinct() throws {
        XCTAssertEqual(try decode("""
        { "state": "pending_approval", "role": "apporteur", "full_name": "Autre Personne" }
        """).state, "pending_approval")

        XCTAssertEqual(try decode("""
        { "state": "suspended", "role": "apporteur", "full_name": "X Y" }
        """).state, "suspended")
    }
}

final class DuplicateCheckTests: XCTestCase {

    private func decode(_ json: String) throws -> DuplicateCheck {
        try SupabaseClient.decoder.decode(DuplicateCheck.self, from: Data(json.utf8))
    }

    /// A lead already in your own list is a mistake worth blocking. One held by
    /// another apporteur is a judgement call that stays theirs to make — the app
    /// warns and gets out of the way.
    func testOwnDuplicateBlocksButContestedOneDoesNot() throws {
        let mine = try decode("""
        { "already_yours": true, "held_by_someone_else": false }
        """)
        XCTAssertTrue(mine.blocksSubmission)
        XCTAssertEqual(mine.warning, Strings.Duplicate.alreadyYours)

        let contested = try decode("""
        { "already_yours": false, "held_by_someone_else": true }
        """)
        XCTAssertFalse(contested.blocksSubmission)
        XCTAssertEqual(contested.warning, Strings.Duplicate.heldByAnother)
    }

    func testCleanLeadProducesNoWarning() throws {
        let clean = try decode("""
        { "already_yours": false, "held_by_someone_else": false }
        """)
        XCTAssertNil(clean.warning)
        XCTAssertFalse(clean.blocksSubmission)
    }

    func testReminderDecodesAndFlagsOverdue() throws {
        let reminder = try SupabaseClient.decoder.decode(Reminder.self, from: Data("""
        { "id": "66666666-6666-6666-6666-666666666666", "label": "Relancer Thomas",
          "due_at": "2020-01-01T09:00:00+00:00", "status": "scheduled" }
        """.utf8))
        XCTAssertEqual(reminder.label, "Relancer Thomas")
        XCTAssertTrue(reminder.isOverdue)
    }

    func testCompletedReminderIsNeverOverdue() throws {
        let reminder = try SupabaseClient.decoder.decode(Reminder.self, from: Data("""
        { "id": "77777777-7777-7777-7777-777777777777", "label": "Fait",
          "due_at": "2020-01-01T09:00:00+00:00", "status": "done" }
        """.utf8))
        XCTAssertFalse(reminder.isOverdue)
    }
}
