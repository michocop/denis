import XCTest
@testable import EnergyCourtage

/// Exercises the session paths against a scripted server.
///
/// These are the parts of auth that a live PostgREST cannot test, because the
/// integration harness mints its own JWTs and never speaks to GoTrue. The
/// refresh-on-401 retry in particular had never run: it is the kind of code
/// that looks obviously right and either loops forever or silently stops
/// refreshing, and neither shows up until someone leaves the app open.
final class AuthFlowTests: XCTestCase {

    private let base = URL(string: "https://project.supabase.co")!

    private func makeClient() -> SupabaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedProtocol.self]
        return SupabaseClient(baseURL: base, anonKey: "anon-key",
                              session: URLSession(configuration: configuration))
    }

    override func setUp() {
        super.setUp()
        ScriptedProtocol.requests = []
        ScriptedProtocol.handler = nil
    }

    private static let freshSession = """
    {"access_token":"new-token","refresh_token":"r2",
     "user":{"id":"11111111-1111-1111-1111-111111111111","email":"a@b.test"}}
    """

    private struct Row: Decodable {}

    // MARK: - The expiry that motivated all of this

    func testAnExpiredTokenIsRefreshedOnceAndTheRequestRetried() async throws {
        let restCalls = Counter()
        ScriptedProtocol.handler = { request in
            if request.url?.path.contains("auth") == true {
                return .init(status: 200, body: Self.freshSession)
            }
            restCalls.bump()
            return restCalls.value == 1
                ? .init(status: 401, body: #"{"message":"JWT expired"}"#)
                : .init(status: 200, body: "[]")
        }

        let client = makeClient()
        await client.setAccessToken("stale-token")
        await client.setRefreshToken("r1")

        let _: [Row] = try await client.get("recommendations")

        let paths = ScriptedProtocol.requests.map { $0.url?.path ?? "" }
        XCTAssertEqual(paths, ["/rest/v1/recommendations",
                               "/auth/v1/token",
                               "/rest/v1/recommendations"],
                       "the 401 is followed by a refresh and then the original request again")

        XCTAssertEqual(ScriptedProtocol.requests.last?
                        .value(forHTTPHeaderField: "Authorization"),
                       "Bearer new-token",
                       "the retry carries the refreshed token, not the stale one")
    }

    /// The refreshed token has to be kept, or every later request pays for
    /// another refresh — and a `let` parameter shadowing the property once made
    /// exactly that bug.
    func testTheRefreshedTokenIsKeptForLaterRequests() async throws {
        let restCalls = Counter()
        ScriptedProtocol.handler = { request in
            if request.url?.path.contains("auth") == true {
                return .init(status: 200, body: Self.freshSession)
            }
            restCalls.bump()
            return restCalls.value == 1
                ? .init(status: 401, body: "{}")
                : .init(status: 200, body: "[]")
        }

        let client = makeClient()
        await client.setAccessToken("stale-token")
        await client.setRefreshToken("r1")

        let _: [Row] = try await client.get("recommendations")
        ScriptedProtocol.requests = []
        let _: [Row] = try await client.get("offers")

        XCTAssertEqual(ScriptedProtocol.requests.count, 1,
                       "the second call does not refresh again")
        XCTAssertEqual(ScriptedProtocol.requests.first?
                        .value(forHTTPHeaderField: "Authorization"),
                       "Bearer new-token")
    }

    /// A password change elsewhere invalidates the refresh token too. The
    /// client must give up rather than retry itself into a corner.
    func testAPermanently401ingSessionGivesUpInsteadOfLooping() async {
        ScriptedProtocol.handler = { _ in .init(status: 401, body: "{}") }

        let client = makeClient()
        await client.setAccessToken("stale-token")
        await client.setRefreshToken("r1")

        do {
            let _: [Row] = try await client.get("recommendations")
            XCTFail("a session that cannot be refreshed must surface an error")
        } catch {
            // one original, one refresh attempt, one retry: no more
            XCTAssertLessThanOrEqual(ScriptedProtocol.requests.count, 3,
                                     "the retry must not itself be retried")
        }
    }

    func testWithoutARefreshTokenA401SurfacesImmediately() async {
        ScriptedProtocol.handler = { _ in .init(status: 401, body: "{}") }

        let client = makeClient()
        await client.setAccessToken("stale-token")

        do {
            let _: [Row] = try await client.get("recommendations")
            XCTFail("expected the 401 to surface")
        } catch {
            XCTAssertEqual(ScriptedProtocol.requests.count, 1,
                           "nothing to refresh with, so no refresh is attempted")
        }
    }

    // MARK: - Signing in

    func testSigningInStoresTheRefreshTokenForLaterUse() async throws {
        let restCalls = Counter()
        ScriptedProtocol.handler = { request in
            if request.url?.path.contains("auth") == true {
                return .init(status: 200, body: Self.freshSession)
            }
            restCalls.bump()
            return restCalls.value == 1
                ? .init(status: 401, body: "{}")
                : .init(status: 200, body: "[]")
        }

        let client = makeClient()
        _ = try await client.signIn(email: "a@b.test", password: "secret")
        ScriptedProtocol.requests = []

        // Signing in must leave the client able to recover from an expiry
        // without anyone calling setRefreshToken by hand.
        let _: [Row] = try await client.get("recommendations")
        XCTAssertTrue(ScriptedProtocol.requests.contains { $0.url?.path == "/auth/v1/token" },
                      "the refresh token captured at sign-in is used")
    }

    func testSigningOutForgetsBothTokens() async {
        ScriptedProtocol.handler = { _ in .init(status: 401, body: "{}") }

        let client = makeClient()
        await client.setAccessToken("t")
        await client.setRefreshToken("r1")
        await client.signOut()

        do {
            let _: [Row] = try await client.get("recommendations")
            XCTFail("expected a 401")
        } catch {
            XCTAssertEqual(ScriptedProtocol.requests.count, 1,
                           "a signed-out client has nothing to refresh with")
            XCTAssertEqual(ScriptedProtocol.requests.first?
                            .value(forHTTPHeaderField: "Authorization"),
                           "Bearer anon-key",
                           "and falls back to the anon key")
        }
    }

    /// Whether an address has an account is not something an unauthenticated
    /// caller should be able to learn, so this never reports failure.
    func testPasswordResetIsSilentAboutWhetherTheAccountExists() async {
        ScriptedProtocol.handler = { _ in .init(status: 400, body: #"{"message":"not found"}"#) }
        let client = makeClient()
        await client.requestPasswordReset(email: "unknown@example.test")
        XCTAssertEqual(ScriptedProtocol.requests.first?.url?.path, "/auth/v1/recover")
    }
}

/// Mutable counter shared with the stub's closure without capturing a `var`.
private final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func bump() { value += 1 }
}

/// A URLProtocol whose answers are scripted per request.
private final class ScriptedProtocol: URLProtocol {
    struct Response {
        let status: Int
        let body: String
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Response)?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let answer = Self.handler?(request) ?? Response(status: 200, body: "[]")
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status,
                                       httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
