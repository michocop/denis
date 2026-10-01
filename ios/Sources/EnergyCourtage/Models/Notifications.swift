import Foundation

/// A row of `notification_feed`. The title and body are rendered by the
/// database rather than here, so that the banner a push notification shows on
/// the lock screen and the row in this list cannot say different things.
public struct AppNotification: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var kind: String
    public var title: String
    public var body: String
    /// What to open when the row is tapped. Exactly one of these is set,
    /// depending on the kind.
    public var threadId: UUID?
    public var recommendationId: UUID?
    public var invoiceId: UUID?
    public var readAt: Date?
    public var createdAt: Date

    public init(id: UUID, kind: String, title: String, body: String,
                threadId: UUID? = nil, recommendationId: UUID? = nil,
                invoiceId: UUID? = nil,
                readAt: Date? = nil, createdAt: Date) {
        self.id = id; self.kind = kind; self.title = title; self.body = body
        self.threadId = threadId; self.recommendationId = recommendationId
        self.invoiceId = invoiceId
        self.readAt = readAt; self.createdAt = createdAt
    }

    public var isUnread: Bool { readAt == nil }

    public var icon: String {
        switch kind {
        case "stage_advanced":   return "arrow.right.circle"
        case "reward_earned":    return "eurosign.circle"
        case "message_received": return "bubble.left"
        case "invoice_ready":    return "doc.text"
        case "payment_sent":     return "banknote"
        default:                 return "bell"
        }
    }
}

public protocol NotificationsRepository: Sendable {
    func notifications() async throws -> [AppNotification]
    func unreadCount() async throws -> Int
    func markAllRead() async throws
    /// Registering is idempotent: iOS hands the token back on every launch.
    func register(deviceToken: String) async throws
    /// Called on sign-out. A token left attached to whoever registered it puts
    /// their commissions on the next person's lock screen.
    func forgetDevices() async throws
}


// MARK: - Legal documents

/// A document someone is asked to agree to, with the exact text they are shown.
///
/// The body travels with it deliberately: what gets recorded on acceptance is
/// the digest of these bytes, so the app must display the thing it hashes. A
/// summary with a button underneath is not a mandate.
public struct LegalDocument: Identifiable, Hashable, Codable, Sendable {
    public let key: String
    public var version: String
    public var title: String
    public var body: String
    public var sha256: String
    public var publishedAt: Date
    public var accepted: Bool

    public var id: String { "\(key)@\(version)" }
}

public protocol LegalRepository: Sendable {
    /// Every published document, with whether this reader has accepted THIS
    /// version — a revised mandate has to be signed again.
    func documents() async throws -> [LegalDocument]
    /// Sends back the digest of the text that was displayed. The server
    /// refuses a mismatch, so consent can only attach to what was shown.
    func accept(key: String, sha256: String) async throws
}
