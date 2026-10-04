import Foundation

/// What an emailed auth link brings back into the app: a password reset, an
/// address confirmation, or an invitation.
///
/// GoTrue redirects to `trinityenergie://auth-callback` with the session in
/// the URL fragment (`#access_token=…&refresh_token=…&type=recovery`), or with
/// an error (`#error=access_denied&error_code=otp_expired&…`) when the link
/// has expired or been used.
public struct AuthCallback: Equatable, Sendable {
    public static let scheme = "trinityenergie"
    public static let redirectURL = "\(scheme)://auth-callback"

    public enum Kind: String, Sendable {
        case recovery, signup, invite, magiclink
        case emailChange = "email_change"
    }

    public var kind: Kind?
    public var accessToken: String
    public var refreshToken: String

    public enum Failure: Error, Equatable, LocalizedError {
        case expired
        case refused(String)

        public var errorDescription: String? {
            switch self {
            case .expired:
                return "Ce lien a expiré ou a déjà servi. Demandez-en un nouveau."
            case .refused(let reason):
                return reason.isEmpty ? "Ce lien n'est pas valide." : reason
            }
        }
    }

    /// nil when the URL is not an auth callback at all.
    public static func parse(_ url: URL) -> Result<AuthCallback, Failure>? {
        guard url.scheme == scheme, url.host() == "auth-callback" else { return nil }

        // Tokens come in the fragment; some flows and errors use the query.
        var fields: [String: String] = [:]
        for part in [url.fragment(percentEncoded: true), URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery] {
            for pair in (part ?? "").split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = kv.first else { continue }
                let value = kv.count > 1 ? kv[1] : ""
                fields[key] = (value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding) ?? value
            }
        }

        if let error = fields["error"] {
            if fields["error_code"] == "otp_expired" { return .failure(.expired) }
            return .failure(.refused(fields["error_description"] ?? error))
        }
        guard let access = fields["access_token"], !access.isEmpty,
              let refresh = fields["refresh_token"], !refresh.isEmpty else {
            return .failure(.refused(""))
        }
        return .success(AuthCallback(kind: fields["type"].flatMap(Kind.init(rawValue:)),
                                     accessToken: access, refreshToken: refresh))
    }
}
