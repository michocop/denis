import XCTest
@testable import EnergyCourtage

/// The emailed links and the push payloads: the two ways something outside
/// the app tells it where to go.
final class LinksAndPushTests: XCTestCase {

    // MARK: - Emailed links

    func testAPasswordResetLinkCarriesASessionAndSaysWhatItIsFor() throws {
        let url = URL(string: "trinityenergie://auth-callback#access_token=a.b.c&expires_in=3600&refresh_token=r1&token_type=bearer&type=recovery")!
        let callback = try XCTUnwrap(AuthCallback.parse(url)).get()
        XCTAssertEqual(callback.kind, .recovery)
        XCTAssertEqual(callback.accessToken, "a.b.c")
        XCTAssertEqual(callback.refreshToken, "r1")
    }

    func testAnInvitationLinkIsRecognised() throws {
        let url = URL(string: "trinityenergie://auth-callback#access_token=t&refresh_token=r&type=invite")!
        XCTAssertEqual(try XCTUnwrap(AuthCallback.parse(url)).get().kind, .invite)
    }

    func testAnExpiredLinkSaysSoInsteadOfFailingSilently() throws {
        let url = URL(string: "trinityenergie://auth-callback#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired")!
        guard case .failure(let failure) = try XCTUnwrap(AuthCallback.parse(url)) else {
            return XCTFail("an expired link is a failure")
        }
        XCTAssertEqual(failure, .expired)
        XCTAssertTrue(failure.localizedDescription.contains("expiré"))
    }

    func testOtherURLsAreNotTakenForAuthLinks() {
        XCTAssertNil(AuthCallback.parse(URL(string: "https://trinity-energie.fr/#access_token=x")!))
        XCTAssertNil(AuthCallback.parse(URL(string: "trinityenergie://somewhere-else#access_token=x")!))
    }

    // MARK: - Push payloads

    /// The keys send-push puts next to `aps`.
    func testAPushAboutAMessageOpensItsConversation() {
        let thread = UUID()
        let route = NotificationRoute(userInfo: ["aps": ["alert": "x"],
                                                 "thread_id": thread.uuidString,
                                                 "recommendation_id": NSNull(),
                                                 "invoice_id": NSNull()])
        XCTAssertEqual(route, .thread(thread))
    }

    func testAnInvoicePushOpensTheInvoiceEvenThoughItAlsoNamesTheLead() {
        let invoice = UUID()
        let route = NotificationRoute(threadID: nil, recommendationID: UUID(), invoiceID: invoice)
        XCTAssertEqual(route, .invoice(invoice), "the most specific thing wins")
    }

    func testAPushWithNothingToOpenOpensNothing() {
        XCTAssertNil(NotificationRoute(userInfo: ["aps": ["alert": "x"]]))
    }

    @MainActor
    func testATappedNotificationBecomesTheRouteTheTabsFollow() {
        let lead = UUID()
        PushCenter.shared.open(.recommendation(lead))
        XCTAssertEqual(PushCenter.shared.route, .recommendation(lead))
        PushCenter.shared.route = nil
    }

    // MARK: - The reset's requests

    func testTheResetEmailIsAskedToComeBackIntoTheApp() async throws {
        let client = makeClient()
        await client.requestPasswordReset(email: "a@b.test")
        let request = try XCTUnwrap(LinkCapture.requests.last)
        XCTAssertEqual(request.url?.path, "/auth/v1/recover")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "redirect_to" }?.value, "trinityenergie://auth-callback")
    }

    func testTheNewPasswordIsSetOnTheSignedInAccount() async throws {
        let client = makeClient()
        await client.setAccessToken("session-from-the-link")
        try await client.updatePassword("nouveau-mot-de-passe")
        let request = try XCTUnwrap(LinkCapture.requests.last)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/auth/v1/user")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-from-the-link")
    }

    private func makeClient() -> SupabaseClient {
        LinkCapture.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkCapture.self]
        return SupabaseClient(baseURL: URL(string: "https://project.supabase.co")!,
                              anonKey: "anon", session: URLSession(configuration: configuration))
    }
}

private final class LinkCapture: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
