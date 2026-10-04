import Foundation
#if canImport(MetricKit)
import MetricKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Crashes and hangs on the phones, reported to the company.
///
/// iOS collects them itself (MetricKit) and hands them over on a later launch,
/// with stack traces; nothing third-party is involved and nothing about the
/// person beyond who they are is sent. Before this a crash on someone's phone
/// was invisible unless they called. The server bounds what it accepts
/// (report_diagnostic): thirty a day per person, 64 KB each.
public final class DiagnosticsReporter: NSObject, @unchecked Sendable {
    public static let shared = DiagnosticsReporter()

    private let lock = NSLock()
    private var client: SupabaseClient?

    /// Called once someone is signed in: reports need an account to file them.
    public func start(client: SupabaseClient) {
        lock.withLock { self.client = client }
        #if canImport(MetricKit) && os(iOS)
        MXMetricManager.shared.add(self)
        #endif
    }

    public func stop() {
        lock.withLock { client = nil }
        #if canImport(MetricKit) && os(iOS)
        MXMetricManager.shared.remove(self)
        #endif
    }

    func send(kind: String, payload: Data) async {
        guard let client = lock.withLock({ self.client }),
              let json = try? JSONSerialization.jsonObject(with: payload) else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        try? await client.rpcVoid("report_diagnostic", body: [
            "p_kind": AnyEncodable(kind),
            "p_app_version": AnyEncodable("\(version) (\(build))"),
            "p_os_version": AnyEncodable(ProcessInfo.processInfo.operatingSystemVersionString),
            "p_payload": AnyEncodable(JSONValue(json))
        ])
    }
}

#if canImport(MetricKit) && os(iOS)
extension DiagnosticsReporter: MXMetricManagerSubscriber {
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let reports: [(String, [MXDiagnostic]?)] = [
                ("crash", payload.crashDiagnostics),
                ("hang", payload.hangDiagnostics),
                ("cpu", payload.cpuExceptionDiagnostics),
                ("disk", payload.diskWriteExceptionDiagnostics)
            ]
            for (kind, diagnostics) in reports {
                for diagnostic in diagnostics ?? [] {
                    let data = diagnostic.jsonRepresentation()
                    Task { await send(kind: kind, payload: data) }
                }
            }
        }
    }
}
#endif

/// Any JSON value, re-encodable: what JSONSerialization produced, passed on.
struct JSONValue: Encodable, @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        // JSONSerialization hands numbers and booleans back as NSNumber, and
        // any NSNumber casts to Bool -- so a 1 would become true. Only a real
        // CFBoolean is a boolean.
        case let v as NSNumber where CFGetTypeID(v) == CFBooleanGetTypeID():
            try container.encode(v.boolValue)
        case let v as NSNumber: try container.encode(v.doubleValue)
        case let v as String: try container.encode(v)
        case let v as [Any]: try container.encode(v.map(JSONValue.init))
        case let v as [String: Any]: try container.encode(v.mapValues(JSONValue.init))
        default: try container.encodeNil()
        }
    }
}
