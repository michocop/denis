import Foundation
import Network
import Observation

/// Whether the device can reach the network at all.
///
/// Without this, every failure looked the same to the person holding the
/// phone: a request made in a lift came back as "Une erreur est survenue",
/// which reads as "the app is broken" rather than "you have no signal". The
/// distinction matters most in exactly the situation this app is used in —
/// an apporteur in a client's basement, filling in a recommendation.
@Observable
public final class Connectivity: @unchecked Sendable {
    public private(set) var isOnline = true
    /// Bumped each time the device comes back after being offline, so a screen
    /// can retry what failed while it was away without polling for it.
    public private(set) var reconnections = 0

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "connectivity")

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let online = path.status == .satisfied
                if online && !self.isOnline { self.reconnections += 1 }
                self.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
