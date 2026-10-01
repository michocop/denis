import Foundation

// Moved out of the view that first needed it: a model and its repository
// protocol living in a SwiftUI file means the logic cannot be tested, or
// even compiled, without dragging the UI along.

public struct Reminder: Identifiable, Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case scheduled, sent, done, cancelled
    }

    public let id: UUID
    public var label: String
    public var dueAt: Date
    public var status: Status

    public init(id: UUID, label: String, dueAt: Date, status: Status) {
        self.id = id; self.label = label; self.dueAt = dueAt; self.status = status
    }

    public var isOverdue: Bool { status == .scheduled && dueAt < .now }
}

public protocol RemindersRepository: Sendable {
    func reminders(recommendationID: UUID) async throws -> [Reminder]
    func schedule(recommendationID: UUID, label: String, dueAt: Date) async throws -> Reminder
    func complete(reminderID: UUID) async throws
}
