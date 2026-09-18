import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Hands the device's APNs token to the database.
///
/// Nothing sends push notifications yet, and this does not pretend otherwise:
/// sending needs an APNs key held by a server, which is a handover item, not
/// code. What this does is make the client side finished — when the key
/// exists, switching push on is a capability checkbox and a sender function,
/// not an app release.
///
/// It only registers when the app actually carries the push entitlement.
/// Calling `registerForRemoteNotifications()` without it produces a failure
/// callback and a console error on every launch, which trains everyone to
/// ignore console errors.
public enum PushRegistration {

    public static var isAvailable: Bool {
        #if canImport(UIKit)
        // aps-environment is written into the app's entitlements by Xcode when
        // the Push Notifications capability is enabled, and is absent until
        // then — which is exactly the question being asked.
        return Bundle.main.object(forInfoDictionaryKey: "aps-environment") != nil
            || entitlementValue("aps-environment") != nil
        #else
        return false
        #endif
    }

    @MainActor
    public static func registerIfAvailable() {
        #if canImport(UIKit)
        guard isAvailable else { return }
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }

    /// Called from the app delegate with the raw token bytes.
    public static func store(_ tokenData: Data,
                             into repository: NotificationsRepository) async {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        try? await repository.register(deviceToken: token)
    }

    #if canImport(UIKit)
    private static func entitlementValue(_ key: String) -> Any? {
        guard let url = Bundle.main.url(forResource: "archived-expanded-entitlements",
                                        withExtension: "xcent"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist[key]
    }
    #endif
}
