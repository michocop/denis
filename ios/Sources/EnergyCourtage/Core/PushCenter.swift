import Foundation
import Observation
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

/// Where a notification leads.
public enum NotificationRoute: Hashable, Sendable {
    case thread(UUID)
    case recommendation(UUID)
    case invoice(UUID)

    /// From the ids a notification carries -- the push payload send-push
    /// builds, or a row of the in-app list. The most specific one wins: an
    /// invoice notification also names its recommendation.
    public init?(threadID: UUID?, recommendationID: UUID?, invoiceID: UUID?) {
        if let invoiceID { self = .invoice(invoiceID) }
        else if let threadID { self = .thread(threadID) }
        else if let recommendationID { self = .recommendation(recommendationID) }
        else { return nil }
    }

    /// The custom keys send-push puts next to `aps`.
    public init?(userInfo: [AnyHashable: Any]) {
        func id(_ key: String) -> UUID? { (userInfo[key] as? String).flatMap(UUID.init(uuidString:)) }
        self.init(threadID: id("thread_id"), recommendationID: id("recommendation_id"),
                  invoiceID: id("invoice_id"))
    }
}

/// Push notifications, end to end on the device.
///
/// The server side was finished -- tokens table, send-push, the trigger -- and
/// nothing on the phone ever handed iOS's token over: there was no app
/// delegate, so `didRegisterForRemoteNotifications` had nowhere to land, and no
/// notification delegate, so a push arriving with the app open was dropped and
/// a tap opened the app on whatever screen it was last on.
///
/// This holds the token until someone is signed in to attach it to, shows
/// pushes while the app is in front, and turns a tap into a `route` the tabs
/// follow.
@MainActor
@Observable
public final class PushCenter: NSObject {
    public static let shared = PushCenter()

    /// The screen a tapped notification asked for. Whoever opens it sets this
    /// back to nil.
    public var route: NotificationRoute?

    private var pendingToken: Data?
    private var registeredToken: Data?
    private var repository: NotificationsRepository?

    /// Called once someone is signed in. Registers a token iOS handed over
    /// before there was anyone to attach it to.
    public func attach(_ repository: NotificationsRepository) async {
        self.repository = repository
        registeredToken = nil
        if let token = pendingToken { await register(token) }
    }

    /// Signing out: the token is forgotten server-side by AppModel; here the
    /// next person must not inherit it.
    public func detach() {
        repository = nil
        registeredToken = nil
    }

    public func deviceTokenReceived(_ token: Data) async {
        pendingToken = token
        await register(token)
    }

    private func register(_ token: Data) async {
        guard let repository, token != registeredToken else { return }
        await PushRegistration.store(token, into: repository)
        registeredToken = token
    }

    public func open(_ route: NotificationRoute) {
        self.route = route
    }
}

#if canImport(UIKit)
extension PushCenter: UNUserNotificationCenterDelegate {
    /// Shown even with the app open: a message arriving while someone is on
    /// the Home tab is exactly when they want to see it.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let route = NotificationRoute(userInfo: info) else { return }
        await MainActor.run { PushCenter.shared.open(route) }
    }
}

/// The app delegate the app target installs with `@UIApplicationDelegateAdaptor`.
/// It exists for the two callbacks SwiftUI has no other way to receive.
public final class TrinityAppDelegate: NSObject, UIApplicationDelegate {
    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = PushCenter.shared
        return true
    }

    public func application(_ application: UIApplication,
                            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await PushCenter.shared.deviceTokenReceived(deviceToken) }
    }

    public func application(_ application: UIApplication,
                            didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // The simulator and unsigned builds land here. In-app notifications
        // and local reminders still work; only the lock-screen push does not.
        print("push registration failed: \(error.localizedDescription)")
    }
}
#endif
