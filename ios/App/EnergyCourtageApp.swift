import SwiftUI
import EnergyCourtage

@main
struct EnergyCourtageApp: App {
    // Without a delegate iOS had nowhere to hand the push token, so push
    // notifications never reached anyone. See PushCenter.
    @UIApplicationDelegateAdaptor(TrinityAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}
