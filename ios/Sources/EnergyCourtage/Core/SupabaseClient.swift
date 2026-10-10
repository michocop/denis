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
            if (status == 401 || status == 403) && message.isEmpty {
                return "Vous n'avez pas les droits pour cette action."
            }
            if status == 401 || status == 403 {
                return message
            }
            return message.isEmpty ? "Erreur serveur (\(status))." : message
        case .decoding(let detail):
            return "Réponse inattendue du serveur. (\(detail))"
        case .unauthenticated:
            return "Session expirée, veuillez vous reconnecter."
        }
    }
}

/// What can go wrong with an emailed sign-in code, said so a person can act
/// on it. Auth answers in English and in its own shape, so the status decides.
public enum EmailCodeError: LocalizedError, Equatable {
    /// No account for that address (Auth: 422, sign-ups closed).
    case unknownAddress
    /// A code was asked for less than a minute ago (429).
    case tooSoon
    /// Wrong, already used, or older than an hour (401/403).
    case invalidCode
    case unavailable

    init(status: Int, verifying: Bool = false) {
        switch status {
        case 429: self = .tooSoon
        case 401, 403: self = verifying ? .invalidCode : .unavailable
        case 400, 404, 422: self = verifying ? .invalidCode : .unknownAddress
        default: self = .unavailable
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unknownAddress:
            return "Aucun accès n'est ouvert pour cette adresse. Utilisez celle à laquelle Trinity Énergie vous a invité."
        case .tooSoon:
            return "Un code vient d'être envoyé. Patientez une minute avant d'en demander un autre."
        case .invalidCode:
            return "Code incorrect ou expiré. Vérifiez le dernier e-mail reçu, ou demandez un nouveau code."
        case .unavailable:
            return "Le service est momentanément indisponible. Réessayez dans un instant."
        }
    }
}

/// Type-erasing box so request bodies can be built as plain dictionaries.
public struct AnyEncodable: Encodable, Sendable {
    private let encodeTo: @Sendable (Encoder) throws -> Void

    public init<T: Encodable & Sendable>(_ value: T) {
        // Through a single-value container, not `value.encode(to:)`. JSONEncoder
        // writes Decimal, Date and URL specially only when it is handed them;
        // called directly, Decimal encodes its internals, and the commission
        // went out as {"mantissa":[5,0,...],"exponent":2} -- which Postgres
        // refused, so "Définir la commission" never worked against a server.
        encodeTo = { encoder in
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
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
    private let restPath: String
    private let authPath: String
    private let storagePath: String
    private let session: URLSession
    private var accessToken: String?
    private var refreshToken: String?
    private var cachedUserID: UUID?
    private var cachedUserIDToken: String?
    /// The refresh in flight, if any. Several requests that hit a 401 at once
    /// all wait on this one rather than each spending the same refresh token:
    /// Supabase rotates it on use, and treats a second use as token theft.
    private var refreshInFlight: Task<Void, Error>?
    private var onRefreshTokenRotated: (@Sendable (String) -> Void)?

    /// The path prefixes default to what hosted Supabase serves, where
    /// PostgREST and GoTrue sit behind a gateway at /rest/v1 and /auth/v1.
    /// They are settable because a bare PostgREST serves its tables at the
    /// root, which is what the integration tests run against -- and because a
    /// prefix baked into the client is a constant nothing can ever check.
    public init(baseURL: URL,
                anonKey: String,
                restPath: String = "rest/v1",
                authPath: String = "auth/v1",
                storagePath: String = "storage/v1",
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.restPath = restPath
        self.authPath = authPath
        self.storagePath = storagePath
        self.session = session
    }

    /// Appends only the components that exist, so an empty prefix does not
    /// leave a stray slash the server will reject.
    private func makeURL(prefix: String, path: String,
                         query: [URLQueryItem] = []) -> URL {
        var url = baseURL
        if !prefix.isEmpty { url = url.appending(path: prefix) }
        if !path.isEmpty { url = url.appending(path: path) }
        if !query.isEmpty { url = url.appending(queryItems: query) }
        return url
    }

    public func setAccessToken(_ token: String?) { accessToken = token }

    /// Keeping the refresh token lets the client renew a session that expires
    /// while someone is using the app, rather than failing every request until
    /// they quit and reopen it.
    public func setRefreshToken(_ token: String?) { refreshToken = token }

    /// Called with each new refresh token. Supabase replaces the token every
    /// time it is used, so one rotated in the middle of a session has to be
    /// written back to the Keychain -- otherwise the next launch presents the
    /// spent one, and the person is sent back to the sign-in screen.
    public func setRefreshTokenObserver(_ observer: (@Sendable (String) -> Void)?) {
        onRefreshTokenRotated = observer
    }

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
        let url = makeURL(prefix: authPath, path: "token",
                          query: [URLQueryItem(name: "grant_type", value: "password")])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request, authenticated: false)
        request.httpBody = try JSONEncoder().encode(["email": email, "password": password])

        let session: AuthSession = try await perform(request)
        accessToken = session.accessToken
        // Kept here as well as in signUp and restore: without it, signing in
        // normally -- which is how everyone gets in -- left the client with
        // nothing to refresh with, and every session died an hour later at the
        // sign-in screen.
        refreshToken = session.refreshToken
        return session
    }

    /// Registration is invitation-based, so this only creates the auth account;
    /// `redeem_invite` turns it into a profile.
    ///
    /// Returns nil when the project asks for the address to be confirmed first,
    /// which is Supabase's default: GoTrue then answers with the new user and
    /// no session, and there is nobody to be signed in as until the link in
    /// the email has been opened. Decoding that reply as a session used to
    /// fail, and the person was told sign-up had gone wrong when it had not.
    public func signUp(email: String, password: String) async throws -> AuthSession? {
        var request = URLRequest(url: makeURL(prefix: authPath, path: "signup"))
        request.httpMethod = "POST"
        applyHeaders(to: &request, authenticated: false)
        request.httpBody = try JSONEncoder().encode(["email": email, "password": password])

        let data = try await performRaw(request, allowRefresh: false)
        guard let session = try? Self.decoder.decode(AuthSession.self, from: data) else {
            return nil
        }
        accessToken = session.accessToken
        refreshToken = session.refreshToken
        return session
    }

    /// Exchanges a stored refresh token for a live session, so a returning user
    /// does not retype their password.
    // The parameter is named separately from the property on purpose: called
    // `refreshToken`, it shadowed the stored one and the assignment below
    // silently targeted the parameter instead.
    public func restore(refreshToken token: String) async throws -> AuthSession {
        let url = makeURL(prefix: authPath, path: "token",
                          query: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request, authenticated: false)
        request.httpBody = try JSONEncoder().encode(["refresh_token": token])

        // allowRefresh is off: this request IS the refresh, and retrying it on
        // a 401 would recurse until the stack gave out.
        let session: AuthSession = try await perform(request, allowRefresh: false)
        accessToken = session.accessToken
        refreshToken = session.refreshToken
        onRefreshTokenRotated?(session.refreshToken)
        return session
    }

    /// Renews the session once, however many requests discover it expired.
    /// `staleAuthorization` is the header the failed request carried: if the
    /// token has changed since, another request already renewed it and there
    /// is nothing left to do but retry.
    private func renewSession(staleAuthorization: String?) async throws {
        if let accessToken, staleAuthorization != "Bearer \(accessToken)" { return }
        if let refreshInFlight { return try await refreshInFlight.value }
        guard let token = refreshToken else { throw SupabaseError.unauthenticated }

        let task = Task { _ = try await self.restore(refreshToken: token) }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        try await task.value
    }

    /// Always reports success to the caller: whether an address has an account
    /// is not something an unauthenticated request should be able to learn.
    ///
    /// `redirectTo` is where the emailed link lands: the app's own scheme, so
    /// the reset finishes in the app. Without it the link went to the project's
    /// site URL and the person was left on a web page with nowhere to type.
    public func requestPasswordReset(email: String, redirectTo: String? = AuthCallback.redirectURL) async {
        var query: [URLQueryItem] = []
        if let redirectTo { query.append(URLQueryItem(name: "redirect_to", value: redirectTo)) }
        var request = URLRequest(url: makeURL(prefix: authPath, path: "recover", query: query))
        request.httpMethod = "POST"
        applyHeaders(to: &request, authenticated: false)
        request.httpBody = try? JSONEncoder().encode(["email": email])
        _ = try? await performRaw(request)
    }

    /// Emails a six-digit sign-in code. Only to an address that already has
    /// an account -- an invitation creates it -- so this cannot open one.
    public func sendEmailCode(to email: String) async throws {
        var request = URLRequest(url: makeURL(prefix: authPath, path: "otp"))
        request.httpMethod = "POST"
        applyHeaders(to: &request, authenticated: false)
        request.httpBody = try JSONEncoder().encode(
            ["email": AnyEncodable(email), "create_user": AnyEncodable(false)])
        do {
            _ = try await performRaw(request, allowRefresh: false)
        } catch SupabaseError.http(let status, _) {
            throw EmailCodeError(status: status)
        }
    }

    /// Exchanges the emailed code for a session. `email` covers both codes
    /// Auth sends: the sign-in one, and the first one of an account whose
    /// address was never confirmed (an invitation nobody opened).
    public func verifyEmailCode(_ code: String, email: String) async throws -> AuthSession {
        var request = URLRequest(url: makeURL(prefix: authPath, path: "verify"))
        request.httpMethod = "POST"
        applyHeaders(to: &request, authenticated: false)
        request.httpBody = try JSONEncoder().encode(
            ["type": "email", "email": email, "token": code])
        let session: AuthSession
        do {
            session = try await perform(request, allowRefresh: false)
        } catch SupabaseError.http(let status, _) {
            throw EmailCodeError(status: status, verifying: true)
        }
        accessToken = session.accessToken
        refreshToken = session.refreshToken
        return session
    }

    /// Sets a new password for the signed-in account -- the end of a reset,
    /// once the emailed link has signed the person in.
    public func updatePassword(_ password: String) async throws {
        var request = URLRequest(url: makeURL(prefix: authPath, path: "user"))
        request.httpMethod = "PUT"
        applyHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(["password": password])
        _ = try await performRaw(request)
    }

    public func signOut() async {
        accessToken = nil
        refreshToken = nil
        // Or the next person to sign in on this device inherits the last
        // one's identity for as long as the cache lives.
        cachedUserID = nil
        cachedUserIDToken = nil
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
        var request = URLRequest(url: restURL("rpc/\(function)"))
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    /// The function's JSON as returned, for a file the person keeps.
    public func rpcData(_ function: String, body: [String: AnyEncodable] = [:]) async throws -> Data {
        var request = URLRequest(url: restURL("rpc/\(function)"))
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        return try await performRaw(request)
    }

    public func rpcVoid(_ function: String, body: [String: AnyEncodable] = [:]) async throws {
        var request = URLRequest(url: restURL("rpc/\(function)"))
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(body)
        _ = try await performRaw(request)   // refresh-on-401 applies here too
    }

    // MARK: - Edge Functions

    /// Calls a Supabase Edge Function as the signed-in user. A function
    /// answers errors as {"error": "..."}, which becomes the message shown.
    public func invokeFunction<T: Decodable>(_ name: String,
                                             body: [String: AnyEncodable]) async throws -> T {
        var request = URLRequest(url: makeURL(prefix: "functions/v1", path: name))
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        do {
            return try await perform(request)
        } catch SupabaseError.http(let status, let message) where message.isEmpty {
            throw SupabaseError.http(status: status, message: "")
        }
    }

    // MARK: - Identity

    /// Who the current session belongs to, according to the database.
    ///
    /// Not "read profiles and take the first row": that reasoning assumed RLS
    /// narrows profiles to the caller, which holds for an apporteur and not
    /// for an admin, whose policy lets them read everyone. An admin asking
    /// who they were got back whichever row came first.
    ///
    /// Cached against the access token, so it costs one call per session and
    /// cannot survive a sign-out into the next person's session.
    public func currentUserID() async throws -> UUID {
        if let cachedUserID, cachedUserIDToken == accessToken { return cachedUserID }
        let id: UUID? = try await rpc("current_profile_id")
        guard let id else { throw SupabaseError.unauthenticated }
        cachedUserID = id
        cachedUserIDToken = accessToken
        return id
    }

    // MARK: - Storage

    /// Uploads bytes to a Storage bucket. `upsert` is off: an invoice PDF is
    /// written once and must never be silently replaced afterwards, and the
    /// server answering 409 is the cheapest way to find out that it was.
    public func upload(bucket: String, path: String, data: Data,
                       contentType: String, upsert: Bool = false) async throws {
        var request = URLRequest(url: makeURL(prefix: storagePath,
                                              path: "object/\(bucket)/\(path)"))
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(upsert ? "true" : "false", forHTTPHeaderField: "x-upsert")
        request.httpBody = data
        _ = try await performRaw(request)
    }

    /// Removes an object through the Storage API -- deleting the row in SQL
    /// would leave the bytes behind.
    public func removeObject(bucket: String, path: String) async throws {
        var request = URLRequest(url: makeURL(prefix: storagePath,
                                              path: "object/\(bucket)/\(path)"))
        request.httpMethod = "DELETE"
        applyHeaders(to: &request)
        _ = try await performRaw(request)
    }

    public func download(bucket: String, path: String) async throws -> Data {
        var request = URLRequest(url: makeURL(prefix: storagePath,
                                              path: "object/\(bucket)/\(path)"))
        applyHeaders(to: &request)
        return try await performRaw(request)
    }

    // MARK: - Plumbing

    private func restURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        makeURL(prefix: restPath, path: path, query: query)
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

    private func performRaw(_ request: URLRequest,
                            allowRefresh: Bool = true) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.http(status: -1, message: "")
        }

        // A Supabase access token lasts an hour. Without this, an app left open
        // over lunch answers every request with "vous n'avez pas les droits"
        // until it is force-quit -- a permissions error for what is only an
        // expired session. Retried exactly once, so a genuine 401 still surfaces.
        if http.statusCode == 401, allowRefresh, refreshToken != nil {
            try? await renewSession(
                staleAuthorization: request.value(forHTTPHeaderField: "Authorization"))
            var retry = request
            applyHeaders(to: &retry)
            return try await performRaw(retry, allowRefresh: false)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw SupabaseError.http(status: http.statusCode,
                                     message: Self.message(from: data))
        }
        return data
    }

    private func perform<T: Decodable>(_ request: URLRequest,
                                       allowRefresh: Bool = true) async throws -> T {
        let data = try await performRaw(request, allowRefresh: allowRefresh)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw SupabaseError.decoding(String(describing: error))
        }
    }

    /// PostgREST puts the useful part in `message`; a RAISE from one of our
    /// own functions lands there too. Edge Functions answer with `error`.
    private static func message(from data: Data) -> String {
        struct Payload: Decodable { let message: String?; let error: String? }
        let payload = try? JSONDecoder().decode(Payload.self, from: data)
        return payload?.message ?? payload?.error ?? ""
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
            // Explicitly, rather than relying on URL(string:) to reject it:
            // an unset xcconfig variable arrives as an empty string, and that
            // is the normal state before a project exists, not an error.
            !urlString.isEmpty,
            let url = URL(string: urlString),
            let key = bundle.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            !key.isEmpty
        else { throw SupabaseError.notConfigured }
        return (url, key)
    }
}
