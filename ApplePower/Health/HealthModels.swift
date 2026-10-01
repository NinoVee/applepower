import Foundation

/// A single headline value, stored in the metric's canonical unit (see `HealthMetric.Source`).
struct MetricReading: Codable, Equatable {
    var value: Double
    /// When the underlying data was recorded, or when the value last changed for totals.
    var sampleDate: Date?
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case today
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "TODAY"
        case .week: return "7 DAYS"
        case .month: return "30 DAYS"
        }
    }

    var rangeLabel: String {
        switch self {
        case .today: return "DAILY RANGE"
        case .week: return "7-DAY RANGE"
        case .month: return "30-DAY RANGE"
        }
    }

    var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    /// Bar width: hourly for today, daily otherwise.
    var bucket: DateComponents {
        self == .today ? DateComponents(hour: 1) : DateComponents(day: 1)
    }

    func start(relativeTo now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
    }
}

struct HistoryPoint: Equatable {
    var date: Date
    var value: Double?
}

struct MetricHistory: Equatable {
    var range: HistoryRange
    var points: [HistoryPoint] = []
    var total: Double?
    var average: Double?
    var minimum: Double?
    var maximum: Double?
}

enum SleepMath {
    /// Total time covered by `intervals`, counting overlaps once. Several sources (watch, phone, third-party apps)
    /// can record the same night, so a plain sum would over-count.
    static func mergedDuration(_ intervals: [DateInterval]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let open = current, interval.start <= open.end {
                current = DateInterval(start: open.start, end: max(open.end, interval.end))
            } else {
                if let open = current { total += open.duration }
                current = interval
            }
        }
        if let open = current { total += open.duration }
        return total
    }
}
