import Foundation

/// The meetings as the company reads them: what is coming, soonest first, and
/// what has been, latest first. A meeting is past once its time is before now.
public struct AppointmentSchedule: Hashable, Sendable {
    public let upcoming: [Recommendation]
    public let past: [Recommendation]

    public init(_ recommendations: [Recommendation], now: Date = .now) {
        let dated = recommendations
            .compactMap { reco in reco.appointmentAt.map { (date: $0, reco: reco) } }
        upcoming = dated.filter { $0.date >= now }
            .sorted { $0.date < $1.date }.map(\.reco)
        past = dated.filter { $0.date < now }
            .sorted { $0.date > $1.date }.map(\.reco)
    }

    public var isEmpty: Bool { upcoming.isEmpty && past.isEmpty }

    /// What the pickers open on: tomorrow, 10:00.
    public static func defaultDate(now: Date = .now, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}
