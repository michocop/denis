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
}
