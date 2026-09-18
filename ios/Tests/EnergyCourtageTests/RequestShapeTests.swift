import XCTest
@testable import EnergyCourtage

/// Captures the requests the client actually builds.
///
/// The integration suite runs against a bare PostgREST with the path prefixes
/// emptied, so it can never notice a wrong default — and a wrong default is
/// precisely what made every request 404 the first time this client met a real
/// server. These tests pin the production shape instead.
final class RequestShapeTests: XCTestCase {

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapturingProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        CapturingProtocol.captured = []
        super.tearDown()
    }

    private let base = URL(string: "https://project.supabase.co")!

    func testTableReadUsesTheSupabaseRestPrefix() async throws {
        let client = SupabaseClient(baseURL: base, anonKey: "anon-key",
                                    session: makeSession())
        let _: [Stub] = try await client.get("stages", query: [
            URLQueryItem(name: "order", value: "position.asc")
        ])

        let request = try XCTUnwrap(CapturingProtocol.captured.first)
        XCTAssertEqual(request.url?.path, "/rest/v1/stages")
        XCTAssertEqual(request.url?.query, "order=position.asc")
    }

    func testRPCSitsUnderTheSamePrefix() async throws {
        let client = SupabaseClient(baseURL: base, anonKey: "anon-key",
                                    session: makeSession())
        let _: [Stub] = try await client.rpc("dashboard_stats")

        let request = try XCTUnwrap(CapturingProtocol.captured.first)
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/dashboard_stats")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testAuthUsesTheGoTruePrefix() async throws {
        let client = SupabaseClient(baseURL: base, anonKey: "anon-key",
                                    session: makeSession())
        _ = try? await client.signIn(email: "a@b.test", password: "secret")

        let request = try XCTUnwrap(CapturingProtocol.captured.first)
        XCTAssertEqual(request.url?.path, "/auth/v1/token")
        XCTAssertEqual(request.url?.query, "grant_type=password")
    }

    /// Supabase rejects a request without the apikey header even when the
    /// bearer token is valid.
    func testEveryRequestCarriesTheKeyAndABearerToken() async throws {
        let client = SupabaseClient(baseURL: base, anonKey: "anon-key",
                                    session: makeSession())
        let _: [Stub] = try await client.get("offers")

        let request = try XCTUnwrap(CapturingProtocol.captured.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Bearer anon-key",
                       "without a session the anon key stands in as the bearer")

        CapturingProtocol.captured = []
        await client.setAccessToken("user-token")
        let _: [Stub] = try await client.get("offers")

        let authed = try XCTUnwrap(CapturingProtocol.captured.first)
        XCTAssertEqual(authed.value(forHTTPHeaderField: "Authorization"),
                       "Bearer user-token")
        XCTAssertEqual(authed.value(forHTTPHeaderField: "apikey"), "anon-key",
                       "the key is sent alongside the session token, not instead of it")
    }

    /// An insert that does not ask for the row back cannot return one, and
    /// several repositories decode the response.
    func testInsertAsksForTheInsertedRow() async throws {
        let client = SupabaseClient(baseURL: base, anonKey: "anon-key",
                                    session: makeSession())
        let _: [Stub] = try await client.insert("recommendations",
                                                values: ["a": AnyEncodable("b")])

        let request = try XCTUnwrap(CapturingProtocol.captured.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"),
                       "return=representation")
    }

    func testUpsertNamesItsConflictTarget() async throws {
        let client = SupabaseClient(baseURL: base, anonKey: "anon-key",
                                    session: makeSession())
        let _: [Stub] = try await client.upsert("personal_notes",
                                                values: ["a": AnyEncodable("b")],
                                                onConflict: "recommendation_id,author_id")

        let request = try XCTUnwrap(CapturingProtocol.captured.first)
        XCTAssertEqual(request.url?.query, "on_conflict=recommendation_id,author_id")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"),
                       "resolution=merge-duplicates,return=representation")
    }

    /// A bare PostgREST serves tables at the root; the client has to be able to
    /// address that too, which is what the integration suite relies on.
    func testEmptyPrefixLeavesNoStraySlash() async throws {
        let client = SupabaseClient(baseURL: URL(string: "http://localhost:3000")!,
                                    anonKey: "anon-key",
                                    restPath: "", authPath: "",
                                    session: makeSession())
        let _: [Stub] = try await client.get("stages")

        let request = try XCTUnwrap(CapturingProtocol.captured.first)
        XCTAssertEqual(request.url?.path, "/stages")
    }

    private struct Stub: Decodable {}
}

/// Records every request and answers with an empty JSON array.
private final class CapturingProtocol: URLProtocol {
    nonisolated(unsafe) static var captured: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captured.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
