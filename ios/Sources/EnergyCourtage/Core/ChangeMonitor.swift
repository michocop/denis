import Foundation

/// Tells the list that the server has moved on, which is what drives the
/// "De nouveaux éléments sont disponibles" banner.
///
/// The implementation polls a single cheap query rather than holding a
/// WebSocket. That is a deliberate trade: Supabase Realtime would be lower
/// latency, but this app's events are human-paced — an admin advances a stage
/// every few minutes, not every few milliseconds — and a poller survives
/// backgrounding, flaky mobile networks and token refresh without any
/// reconnection logic to get wrong. The protocol is here so a Realtime
/// implementation can replace it without touching a view model.
public protocol ChangeMonitor: Sendable {
    /// Emits once each time the server state has changed since the last check.
    func changes() -> AsyncStream<Void>
}

public struct PollingChangeMonitor: ChangeMonitor {
    private let client: SupabaseClient
    private let interval: Duration

    public init(client: SupabaseClient, interval: Duration = .seconds(30)) {
        self.client = client
        self.interval = interval
    }

    private struct Watermark: Decodable { let updatedAt: Date? }

    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                var seen: Date?
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { break }

                    // One row, one column, indexed: cheap enough to run on a
                    // timer without thinking about it.
                    let rows: [Watermark]? = try? await client.get(
                        "recommendations",
                        query: [
                            URLQueryItem(name: "select", value: "updated_at"),
                            URLQueryItem(name: "order", value: "updated_at.desc"),
                            URLQueryItem(name: "limit", value: "1")
                        ]
                    )
                    guard let latest = rows?.first?.updatedAt else { continue }

                    // The first reading establishes the baseline; only a later
                    // change counts, or the banner would appear on launch.
                    if let previous = seen, latest > previous {
                        continuation.yield(())
                    }
                    seen = latest
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Used by previews and tests, where nothing ever changes.
public struct InertChangeMonitor: ChangeMonitor {
    public init() {}
    public func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}
