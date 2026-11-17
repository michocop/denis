import XCTest
@testable import EnergyCourtage

/// The meeting fixed with a filleul: what the form sends, what the feed gives
/// back, and how the admin's list reads.
final class AppointmentTests: XCTestCase {

    override func tearDown() {
        FeedServer.reset()
        super.tearDown()
    }

    private let paris: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int = 12, _ minute: Int = 0) -> Date {
        paris.date(from: DateComponents(year: year, month: month, day: day,
                                        hour: hour, minute: minute))!
    }

    private func lead(_ name: String, at date: Date?) -> Recommendation {
        Recommendation(id: UUID(), filleulFirstName: name, filleulLastName: "Dubois",
                       parrainName: "Johann Lefeuvre", createdAt: .now,
                       currentStageID: SampleData.stages[0].id, appointmentAt: date)
    }

    private func draft(appointmentAt: Date? = nil) -> RecommendationDraft {
        var draft = RecommendationDraft()
        draft.firstName = "Thomas"
        draft.lastName = "Dubois"
        draft.phone = "+33 6 75 75 75 75"
        draft.consentConfirmed = true
        draft.appointmentAt = appointmentAt
        return draft
    }

    private func repository() -> SupabaseRecommendationsRepository {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedServer.self]
        return SupabaseRecommendationsRepository(client: SupabaseClient(
            baseURL: URL(string: "https://project.supabase.co")!, anonKey: "anon-key",
            session: URLSession(configuration: configuration)))
    }

    // MARK: Draft

    func testADraftIsValidWithOrWithoutAMeeting() {
        XCTAssertNil(RecommendationDraft().appointmentAt)
        XCTAssertTrue(draft().isValid)

        let at = date(2026, 11, 10, 14, 30)
        XCTAssertEqual(draft(appointmentAt: at).appointmentAt, at)
        XCTAssertTrue(draft(appointmentAt: at).isValid)
    }

    func testThePickersOpenOnTomorrowAtTen() {
        XCTAssertEqual(
            AppointmentSchedule.defaultDate(now: date(2026, 11, 30, 18, 47), calendar: paris),
            date(2026, 12, 1, 10, 0)
        )
    }

    // MARK: Requests

    func testCreateSendsTheMeetingAsAnInstant() async throws {
        _ = try await repository().create(draft(appointmentAt: date(2026, 11, 10, 14, 30)))

        let body = try XCTUnwrap(FeedServer.body(of: "POST", path: "/rest/v1/recommendations"))
        XCTAssertEqual(body["appointment_at"] as? String, "2026-11-10T13:30:00Z")
    }

    /// Leaving the key out, rather than sending null, is what "no meeting"
    /// means on an insert.
    func testCreateLeavesTheMeetingOutWhenThereIsNone() async throws {
        _ = try await repository().create(draft())

        let body = try XCTUnwrap(FeedServer.body(of: "POST", path: "/rest/v1/recommendations"))
        XCTAssertFalse(body.keys.contains("appointment_at"))
    }

    func testMovingAMeetingPatchesThatOneRow() async throws {
        let id = FeedServer.id
        let updated = try await repository().setAppointment(
            recommendationID: id, at: date(2026, 11, 10, 14, 30))

        let request = try XCTUnwrap(FeedServer.captured.first { $0.request.httpMethod == "PATCH" })
        XCTAssertEqual(request.request.url?.path, "/rest/v1/recommendations")
        XCTAssertEqual(request.request.url?.query, "id=eq.\(id.uuidString)")
        let body = try XCTUnwrap(FeedServer.body(of: "PATCH", path: "/rest/v1/recommendations"))
        XCTAssertEqual(body["appointment_at"] as? String, "2026-11-10T13:30:00Z")
        XCTAssertEqual(updated.id, id, "the feed is read again, so the caller gets the full row")
    }

    func testRemovingAMeetingWritesARealNull() async throws {
        _ = try await repository().setAppointment(recommendationID: FeedServer.id, at: nil)

        let body = try XCTUnwrap(FeedServer.body(of: "PATCH", path: "/rest/v1/recommendations"))
        XCTAssertTrue(body["appointment_at"] is NSNull, "a missing key would leave the meeting in place")
    }

    /// RLS answers a refused PATCH with an empty list and a 200.
    func testAPatchThatTouchedNoRowIsAnError() async {
        FeedServer.refusesUpdates = true
        do {
            _ = try await repository().setAppointment(recommendationID: FeedServer.id, at: .now)
            XCTFail("a refused update must not read as saved")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Vous n'avez pas les droits pour cette action.")
        }
    }

    func testTheListReadsActiveLeadsWithAMeetingInOrder() async throws {
        _ = try await repository().appointments()

        let request = try XCTUnwrap(FeedServer.captured.first {
            $0.request.url?.path == "/rest/v1/recommendation_feed"
        })
        XCTAssertEqual(request.request.url?.query,
                       "appointment_at=not.is.null&status=eq.active&order=appointment_at.asc")
    }

    // MARK: Feed

    func testTheFeedRowCarriesTheMeeting() async throws {
        FeedServer.appointmentJSON = #""appointment_at": "2026-11-10T13:30:00+00:00","#
        let rows = try await repository().appointments()
        XCTAssertEqual(rows.first?.appointmentAt, date(2026, 11, 10, 14, 30))
    }

    func testTheFeedRowDecodesWithANullMeeting() async throws {
        FeedServer.appointmentJSON = #""appointment_at": null,"#
        let rows = try await repository().appointments()
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.appointmentAt)
    }

    /// The server may be deployed after the app: a feed that predates the
    /// column must not empty the lists.
    func testTheFeedRowDecodesWithoutTheColumn() async throws {
        FeedServer.appointmentJSON = ""
        let rows = try await repository().appointments()
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.appointmentAt)
    }

    // MARK: The list

    func testTheScheduleSplitsAroundNow() {
        let now = date(2026, 11, 5, 15, 0)
        let lastWeek = lead("A", at: date(2026, 10, 29))
        let thisMorning = lead("B", at: date(2026, 11, 5, 9, 0))
        let tonight = lead("C", at: date(2026, 11, 5, 18, 0))
        let nextWeek = lead("D", at: date(2026, 11, 12))

        let schedule = AppointmentSchedule([nextWeek, lastWeek, tonight, thisMorning], now: now)

        XCTAssertEqual(schedule.upcoming.map(\.id), [tonight.id, nextWeek.id], "soonest first")
        XCTAssertEqual(schedule.past.map(\.id), [thisMorning.id, lastWeek.id], "latest first")
        XCTAssertFalse(schedule.isEmpty)
    }

    func testAMeetingIsPastOnlyOnceItsTimeIsBeforeNow() {
        let now = date(2026, 11, 5, 15, 0)
        let onTheDot = AppointmentSchedule([lead("A", at: now)], now: now)
        XCTAssertEqual(onTheDot.upcoming.count, 1)

        let gone = AppointmentSchedule([lead("A", at: now.addingTimeInterval(-1))], now: now)
        XCTAssertEqual(gone.past.count, 1)
    }

    func testALeadWithoutAMeetingIsNotInTheSchedule() {
        XCTAssertTrue(AppointmentSchedule([lead("A", at: nil)]).isEmpty)
    }

    // MARK: Wording

    func testTheDateReadsInFrench() {
        let now = date(2026, 11, 5)
        XCTAssertEqual(RecommendationCard.appointmentDate(date(2026, 11, 10, 14, 30),
                                                          now: now, calendar: paris),
                       "mardi 10 novembre à 14:30")
        XCTAssertEqual(RecommendationCard.appointmentDate(date(2026, 12, 1, 9, 5),
                                                          now: now, calendar: paris),
                       "mardi 1er décembre à 09:05")
    }

    func testAnotherYearIsNamed() {
        XCTAssertEqual(RecommendationCard.appointmentDate(date(2027, 1, 12, 14, 30),
                                                          now: date(2026, 11, 5), calendar: paris),
                       "mardi 12 janvier 2027 à 14:30")
    }

    // MARK: Demo

    func testTheDemoHasAMeetingAhead() async throws {
        let appointments = try await PreviewRecommendationsRepository().appointments()
        XCTAssertFalse(AppointmentSchedule(appointments).upcoming.isEmpty)
    }

    func testTheDemoKeepsWhatIsDone() async throws {
        let repository = PreviewRecommendationsRepository(items: [])
        let at = date(2030, 3, 12, 10, 0)

        let created = try await repository.create(draft(appointmentAt: at))
        XCTAssertEqual(created.appointmentAt, at)

        let moved = at.addingTimeInterval(3_600)
        _ = try await repository.setAppointment(recommendationID: created.id, at: moved)
        var list = try await repository.appointments()
        XCTAssertEqual(list.first?.appointmentAt, moved)

        _ = try await repository.setAppointment(recommendationID: created.id, at: nil)
        list = try await repository.appointments()
        XCTAssertTrue(list.isEmpty)
    }

    func testAClosedDealLeavesTheDemoList() async throws {
        let repository = PreviewRecommendationsRepository()
        try await repository.archive(recommendationID: SampleData.inProgressRecommendation.id, won: true)
        let list = try await repository.appointments()
        XCTAssertFalse(list.contains { $0.id == SampleData.inProgressRecommendation.id })
    }

    @MainActor
    func testTheScreenSaysEmptyOnlyOnceItHasAnAnswer() async {
        let model = AppointmentsViewModel(repository: PreviewRecommendationsRepository(items: []))
        XCTAssertFalse(model.isEmpty)
        await model.load()
        XCTAssertTrue(model.isEmpty)
    }
}

/// Answers each request the repository makes as PostgREST would.
private final class FeedServer: URLProtocol {
    static let id = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    nonisolated(unsafe) static var captured: [(request: URLRequest, body: Data)] = []
    nonisolated(unsafe) static var appointmentJSON = ""
    nonisolated(unsafe) static var refusesUpdates = false

    static func reset() {
        captured = []
        appointmentJSON = ""
        refusesUpdates = false
    }

    static func body(of method: String, path: String) -> [String: Any]? {
        captured
            .first { $0.request.httpMethod == method && $0.request.url?.path == path }
            .flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }
    }

    private var answer: String {
        switch request.url?.path {
        case "/rest/v1/rpc/current_profile_id":
            return "\"\(UUID().uuidString)\""
        case "/rest/v1/stages":
            return """
            [{ "id": "\(SampleData.stages[0].id.uuidString)", "key": "a_contacter",
               "label": "À contacter", "position": 1,
               "is_reward_trigger": false, "is_terminal": false }]
            """
        case "/rest/v1/recommendation_feed":
            return """
            [{ "id": "\(Self.id.uuidString)", \(Self.appointmentJSON)
               "filleul_first_name": "Thomas", "filleul_last_name": "Dubois",
               "filleul_phone": "+33 6 75 75 75 75", "parrain_name": "Johann Lefeuvre",
               "created_at": "2026-11-01T09:00:00+00:00",
               "current_stage_key": "a_contacter", "reward_status": "pending",
               "status": "active", "displayed_amount": null, "reward_amount": null,
               "events": [], "has_contract": false, "invoice_number": null,
               "invoice_id": null, "days_since_activity": 0, "has_note": false,
               "pending_reminders": 0, "apporteur_comment": null }]
            """
        case "/rest/v1/recommendations" where request.httpMethod == "PATCH" && Self.refusesUpdates:
            return "[]"
        default:
            return "[{ \"id\": \"\(Self.id.uuidString)\" }]"
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                body.append(buffer, count: read)
            }
        }
        Self.captured.append((request, body))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
