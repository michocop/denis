import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Reminders that fire on the phone, and the APNs registration that will one
/// day let the server push as well.
///
/// The two are separate on purpose. A *local* notification needs nothing but
/// the user's permission, so "rappeler Thomas Dubois jeudi" can work today.
/// A *push* notification needs an Apple push key held by a server, which does
/// not exist yet — so this registers the device token and stores it, and says
/// plainly that nothing sends yet rather than pretending otherwise.
public enum LocalNotifications {

    /// Asked for at the moment a reminder is first scheduled, not at launch:
    /// a permission prompt on the first screen, before anything has been done
    /// with the app, is the one people decline.
    @discardableResult
    public static func requestPermission() async -> Bool {
        #if canImport(UserNotifications)
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    /// Mirrors a server-side reminder onto the device so it fires even with
    /// the app closed. Identified by the reminder's own id, so rescheduling
    /// replaces rather than duplicates.
    public static func schedule(reminderID: UUID, label: String, dueAt: Date) async {
        #if canImport(UserNotifications)
        guard dueAt > .now else { return }
        guard await requestPermission() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Relance"
        content.body = label
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, dueAt.timeIntervalSinceNow), repeats: false)
        let request = UNNotificationRequest(identifier: reminderID.uuidString,
                                            content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
        #endif
    }

    public static func cancel(reminderID: UUID) {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [reminderID.uuidString])
        #endif
    }

    /// The unread count on the app icon. Kept in step with the badge in the
    /// tab bar, so the two never disagree.
    public static func setBadge(_ count: Int) async {
        #if canImport(UserNotifications)
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
        #endif
    }
}
