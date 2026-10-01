import SwiftUI

/// Pure black background, white and grey text. On OLED every black pixel is switched off, so the palette
/// deliberately has no fills, gradients or accent colours. Large numerals use light weights: thinner strokes
/// light fewer pixels.
enum Theme {
    static let background = Color.black
    static let primary = Color.white
    static let secondary = Color(white: 0.6)
    static let tertiary = Color(white: 0.4)
    /// Always-On: dimmer and thinner still.
    static let dimmed = Color(white: 0.45)

    static func numeral(_ size: CGFloat, dimmed: Bool = false) -> Font {
        .system(size: size, weight: dimmed ? .thin : .light).monospacedDigit()
    }

    static let label = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 11, weight: .regular)
}

struct FormattedValue: Equatable {
    var value: String
    var unit: String

    /// "72 BPM", "98%".
    var inline: String {
        if unit.isEmpty { return value }
        return unit == "%" || unit.hasPrefix("°") ? value + unit : "\(value) \(unit)"
    }
}

enum MetricFormatter {
    static func format(_ metric: HealthMetric, _ value: Double, units: UnitSystem) -> FormattedValue {
        switch metric {
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage:
            return FormattedValue(value: number(value, digits: 0), unit: "BPM")
        case .heartRateVariability:
            return FormattedValue(value: number(value, digits: 0), unit: "MS")
        case .bloodOxygen:
            return FormattedValue(value: number(value * 100, digits: 0), unit: "%")
        case .respiratoryRate:
            return FormattedValue(value: number(value, digits: 1), unit: "BR/MIN")
        case .wristTemperature:
            return units == .imperial
                ? FormattedValue(value: number(value * 9 / 5 + 32, digits: 1), unit: "°F")
                : FormattedValue(value: number(value, digits: 1), unit: "°C")
        case .steps:
            return FormattedValue(value: number(value, digits: 0), unit: "STEPS")
        case .walkingRunningDistance, .cyclingDistance:
            return distance(value, units: units)
        case .activeEnergy:
            return FormattedValue(value: number(value, digits: 0), unit: "CAL")
        case .exerciseMinutes:
            return FormattedValue(value: number(value, digits: 0), unit: "MIN")
        case .standHours:
            return FormattedValue(value: number(value, digits: 0), unit: "HRS")
        case .flightsClimbed:
            return FormattedValue(value: number(value, digits: 0), unit: "FLOORS")
        case .workouts:
            return FormattedValue(value: number(value, digits: 0), unit: value.rounded() == 1 ? "WORKOUT" : "WORKOUTS")
        case .sleep:
            return FormattedValue(value: hoursMinutes(value), unit: "ASLEEP")
        case .vo2Max:
            return FormattedValue(value: number(value, digits: 1), unit: "ML/KG·MIN")
        }
    }

    /// "58–142 BPM".
    static func range(_ metric: HealthMetric, low: Double, high: Double, units: UnitSystem) -> String {
        let lower = format(metric, low, units: units)
        let upper = format(metric, high, units: units)
        return FormattedValue(value: "\(lower.value)–\(upper.value)", unit: upper.unit).inline
    }

    static func distance(_ meters: Double, units: UnitSystem) -> FormattedValue {
        units == .imperial
            ? FormattedValue(value: number(meters / 1609.344, digits: 2), unit: "MI")
            : FormattedValue(value: number(meters / 1000, digits: 2), unit: "KM")
    }

    static func number(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// Seconds → "7:12".
    static func hoursMinutes(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// Date formatters are expensive to create, so each pattern is built once.
enum DisplayFormat {
    private static let time12 = formatter("h:mm")
    private static let time24 = formatter("HH:mm")
    private static let stamp12 = formatter("h:mm a")
    private static let dateLine = formatter("EEE MMM d")
    private static let monthDay = formatter("MMM d")

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = pattern
        return formatter
    }

    /// "10:42" — no seconds, no AM/PM, like a plain digital watch.
    static func time(_ date: Date, _ format: TimeFormat) -> String {
        (format == .twelveHour ? time12 : time24).string(from: date)
    }

    /// "TUE SEP 30".
    static func dateLine(_ date: Date) -> String {
        dateLine.string(from: date).uppercased()
    }

    /// "10:38 PM" today, otherwise "SEP 29".
    static func lastUpdated(_ date: Date, _ format: TimeFormat, now: Date = .now) -> String {
        if Calendar.autoupdatingCurrent.isDate(date, inSameDayAs: now) {
            return (format == .twelveHour ? stamp12 : time24).string(from: date).uppercased()
        }
        return monthDay.string(from: date).uppercased()
    }

    /// "00:32:18", or "00:32" when seconds aren't being drawn (Always-On).
    static func elapsed(_ interval: TimeInterval, showSeconds: Bool) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let seconds = total % 60
        return showSeconds
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", hours, minutes)
    }
}
