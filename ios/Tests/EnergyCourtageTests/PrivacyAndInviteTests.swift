import XCTest
@testable import EnergyCourtage

final class PrivacyAndInviteTests: XCTestCase {

    /// A crash report passes through as the JSON iOS produced, numbers as
    /// numbers and booleans as booleans.
    func testADiagnosticIsPassedOnAsTheSameJSON() throws {
        let original = #"{"signal": 6, "isMainThread": true, "frames": [{"offset": 1024}], "name": "SIGABRT"}"#
        let parsed = try JSONSerialization.jsonObject(with: Data(original.utf8))
        let encoded = try JSONEncoder().encode(JSONValue(parsed))
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(back["signal"] as? Double, 6)
        XCTAssertEqual((back["isMainThread"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() }, true)
        XCTAssertEqual(back["name"] as? String, "SIGABRT")
        XCTAssertEqual(((back["frames"] as? [[String: Any]])?.first?["offset"]) as? Double, 1024)
    }

    /// Invitations go through the send-invite function, which also emails them.
    func testAnInvitationIsSentThroughTheFunctionThatEmailsIt() async throws {
        FunctionCapture.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FunctionCapture.self]
        let client = SupabaseClient(baseURL: URL(string: "https://project.supabase.co")!,
                                    anonKey: "anon", session: URLSession(configuration: configuration))
        await client.setAccessToken("admin-session")
        let invite = try await SupabaseAdminRepository(client: client)
            .createInvite(email: "nina@example.test", role: .apporteur, autoActivate: true)

        XCTAssertEqual(invite, Invite(code: "ABCD2345", email: "nina@example.test"))
        let request = try XCTUnwrap(FunctionCapture.requests.first)
        XCTAssertEqual(request.url?.path, "/functions/v1/send-invite")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer admin-session",
                       "as the admin, whose rights the function checks")
    }

    /// A function's refusal reads as its own message, not a generic one.
    func testAFunctionsRefusalIsShownInItsOwnWords() async {
        FunctionCapture.requests = []
        FunctionCapture.status = 409
        defer { FunctionCapture.status = 200 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FunctionCapture.self]
        let client = SupabaseClient(baseURL: URL(string: "https://project.supabase.co")!,
                                    anonKey: "anon", session: URLSession(configuration: configuration))
        do {
            _ = try await SupabaseAdminRepository(client: client)
                .createInvite(email: "johann@example.test", role: .apporteur, autoActivate: true)
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Un compte existe déjà pour cette adresse.")
        }
    }
}

private final class FunctionCapture: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let body = Self.status == 200
            ? #"{"email":"nina@example.test","code":"ABCD2345"}"#
            : #"{"error":"Un compte existe déjà pour cette adresse."}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
