import Foundation

/// A small PostgREST / GoTrue client built on URLSession.
///
/// Deliberately not the official SDK: the app needs table reads, RPC calls and
/// password auth, which is a few hundred lines, and keeping it first-party
/// means no dependency to resolve and one place to look when a request
/// misbehaves. Swap it for supabase-swift later without touching a repository —
/// they all talk to the protocol below, not to this type.
public protocol SupabaseTransport: Sendable {
    func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T
    func rpc<T: Decodable>(_ function: String, body: [String: AnyEncodable]) async throws -> T
    func rpcVoid(_ function: String, body: [String: AnyEncodable]) async throws
    func insert<T: Decodable>(_ table: String, values: [String: AnyEncodable]) async throws -> T
    func update<T: Decodable>(_ table: String, values: [String: AnyEncodable],
                              match: [URLQueryItem]) async throws -> T
}

public enum SupabaseError: LocalizedError {
    case notConfigured
    case http(status: Int, message: String)
    case decoding(String)
    case unauthenticated

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Configuration Supabase manquante (SUPABASE_URL / SUPABASE_ANON_KEY)."
        case .http(let status, let message):
            // PostgREST returns 42501 for an RLS refusal; say something a user
            // can act on rather than surfacing the raw code.
            if status == 401 || status == 403 {
                return "Vous n'avez pas les droits pour cette action."
            }
            return message.isEmpty ? "Erreur serveur (\(status))." : message
        case .decoding(let detail):
            return "Réponse inattendue du serveur. (\(detail))"
        case .unauthenticated:
            return "Session expirée, veuillez vous reconnecter."
        }
    }
}

/// Type-erasing box so request bodies can be built as plain dictionaries.
public struct AnyEncodable: Encodable, Sendable {
    private let encodeTo: @Sendable (Encoder) throws -> Void

    public init<T: Encodable & Sendable>(_ value: T) {
        encodeTo = { encoder in try value.encode(to: encoder) }
    }

    public init(nilLiteral: ()) {
        encodeTo = { encoder in
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    public func encode(to encoder: Encoder) throws { try encodeTo(encoder) }
}

public actor SupabaseClient: SupabaseTransport {

    private let baseURL: URL
    private let anonKey: String
    private let session: URLSession
    private var accessToken: String?

    public init(baseURL: URL, anonKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.session = session
    }

    public func setAccessToken(_ token: String?) { accessToken = token }

    // MARK: - Auth

    public struct AuthSession: Decodable, Sendable {
        public let accessToken: String
        public let refreshToken: String
        public let user: AuthUser
        // No CodingKeys: the decoder's .convertFromSnakeCase already maps
        // access_token -> accessToken, and a CodingKey would fight it.
    }

    public struct AuthUser: Decodable, Sendable {
        public let id: UUID
        public let email: String?
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        let url = baseURL.appending(path: "auth/v1/token")
            .appending(queryItems: [URLQueryItem(name: "grant_type", value: "password")])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request, authenticated: false)
        request.httpBody = try JSONEncoder().encode(["email": email, "password": password])

        let session: AuthSession = try await perform(request)
        accessToken = session.accessToken
        return session
    }

    /// Registration is invitation-based, so this only creates the auth account;
    /// `redeem_invite` turns it into a profile.
    public func signUp(email: String, password: String) async throws -> AuthSession {
        var request = URLRequest(url: baseURL.appending(path: "auth/v1/signup"))
        request.httpMethod = "POST"
        applyHeaders(to: &request, authenticated: false)
        request.httpBody = try JSONEncoder().encode(["email": email, "password": password])

        let session: AuthSession = try await perform(request)
        accessToken = session.accessToken
        return session
    }

    /// Exchanges a stored refresh token for a live session, so a returning user
    /// does not retype their password.
    public func restore(refreshToken: String) async throws -> AuthSession {
        let url = baseURL.appending(path: "auth/v1/token")
            .appending(queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request, authenticated: false)
        request.httpBody = try JSONEncoder().encode(["refresh_token": refreshToken])

        let session: AuthSession = try await perform(request)
        accessToken = session.accessToken
        return session
    }

    /// Always reports success to the caller: whether an address has an account
    /// is not something an unauthenticated request should be able to learn.
    public func requestPasswordReset(email: String) async {
        var request = URLRequest(url: baseURL.appending(path: "auth/v1/recover"))
        request.httpMethod = "POST"
        applyHeaders(to: &request, authenticated: false)
        request.httpBody = try? JSONEncoder().encode(["email": email])
        _ = try? await performRaw(request)
    }

    public func signOut() async {
        accessToken = nil
    }

    // MARK: - PostgREST

    public func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var request = URLRequest(url: restURL(path, query: query))
        request.httpMethod = "GET"
        applyHeaders(to: &request)
        return try await perform(request)
    }

    public func insert<T: Decodable>(_ table: String,
                                     values: [String: AnyEncodable]) async throws -> T {
        var request = URLRequest(url: restURL(table))
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        // return=representation makes PostgREST answer with the inserted row —
        // which is why every insertable table needs a SELECT policy that can
        // see its own new row.
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(values)
        return try await perform(request)
    }

    /// Insert-or-replace against a unique constraint. Used for the personal
    /// note, which is one row per reader per recommendation.
    public func upsert<T: Decodable>(_ table: String,
                                     values: [String: AnyEncodable],
                                     onConflict: String) async throws -> T {
        var request = URLRequest(url: restURL(table, query: [
            URLQueryItem(name: "on_conflict", value: onConflict)
        ]))
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.setValue("resolution=merge-duplicates,return=representation",
                         forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(values)
        return try await perform(request)
    }

    public func update<T: Decodable>(_ table: String,
                                     values: [String: AnyEncodable],
                                     match: [URLQueryItem]) async throws -> T {
        var request = URLRequest(url: restURL(table, query: match))
        request.httpMethod = "PATCH"
        applyHeaders(to: &request)
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(values)
        return try await perform(request)
    }

    public func rpc<T: Decodable>(_ function: String,
                                  body: [String: AnyEncodable] = [:]) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: "rest/v1/rpc/\(function)"))
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    public func rpcVoid(_ function: String, body: [String: AnyEncodable] = [:]) async throws {
        var request = URLRequest(url: baseURL.appending(path: "rest/v1/rpc/\(function)"))
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(body)
        _ = try await performRaw(request)
    }

    // MARK: - Plumbing

    private func restURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        var url = baseURL.appending(path: "rest/v1/\(path)")
        if !query.isEmpty { url = url.appending(queryItems: query) }
        return url
    }

    private func applyHeaders(to request: inout URLRequest, authenticated: Bool = true) {
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func performRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.http(status: -1, message: "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SupabaseError.http(status: http.statusCode,
                                     message: Self.message(from: data))
        }
        return data
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await performRaw(request)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw SupabaseError.decoding(String(describing: error))
        }
    }

    /// PostgREST puts the useful part in `message`; a RAISE from one of our
    /// own functions lands there too.
    private static func message(from data: Data) -> String {
        struct Payload: Decodable { let message: String? }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.message ?? ""
    }

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = iso8601WithFraction.date(from: text) { return date }
            if let date = iso8601.date(from: text) { return date }
            if let date = plainDate.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unrecognised date: \(text)"
            )
        }
        return decoder
    }()

    // Postgres timestamps arrive with or without fractional seconds depending
    // on the value, and `date` columns arrive bare.
    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let plainDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Configuration

public enum AppConfig {
    /// Read from Info.plist so keys live in the build configuration rather than
    /// in source. The anon key is public by design — it grants nothing on its
    /// own, because every table is behind RLS.
    public static func supabase(bundle: Bundle = .main) throws -> (url: URL, key: String) {
        guard
            let urlString = bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let url = URL(string: urlString),
            let key = bundle.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            !key.isEmpty
        else { throw SupabaseError.notConfigured }
        return (url, key)
    }
}
