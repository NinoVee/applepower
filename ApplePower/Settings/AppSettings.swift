import Foundation
import Observation
import SwiftUI

enum TimeFormat: String, CaseIterable {
    case twelveHour
    case twentyFourHour

    var label: String { self == .twelveHour ? "12 HOUR" : "24 HOUR" }
}

enum UnitSystem: String, CaseIterable {
    case imperial
    case metric

    var label: String { self == .imperial ? "IMPERIAL" : "METRIC" }
}

enum AnimationMode: String, CaseIterable {
    case minimal
    case off

    var label: String { self == .minimal ? "MINIMAL" : "OFF" }

    /// The only animation in the app: a short cross-fade between crown pages.
    var animation: Animation? { self == .minimal ? .easeOut(duration: 0.15) : nil }
}

extension CaseIterable where Self: Equatable, AllCases: BidirectionalCollection {
    var next: Self {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        let following = all.index(after: index)
        return following == all.endIndex ? all.first! : all[following]
    }
}

/// User preferences, persisted in UserDefaults.
/// Each public property writes through on set; the private stored copies are what Observation tracks.
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let timeFormat = "settings.timeFormat"
        static let units = "settings.units"
        static let haptics = "settings.haptics"
        static let animation = "settings.animation"
        static let showDate = "settings.clock.showDate"
        static let showHeartRate = "settings.clock.showHeartRate"
        static let showBattery = "settings.clock.showBattery"
        static let metricOrder = "settings.metricOrder"
        static let enabledMetrics = "settings.enabledMetrics"
    }

    @ObservationIgnored private let defaults: UserDefaults

    private var storedTimeFormat: TimeFormat
    private var storedUnits: UnitSystem
    private var storedHaptics: Bool
    private var storedAnimation: AnimationMode
    private var storedShowDate: Bool
    private var storedShowHeartRate: Bool
    private var storedShowBattery: Bool
    private var storedMetricOrder: [HealthMetric]
    private var storedEnabledMetrics: Set<HealthMetric>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let localeUses12Hour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true
        storedTimeFormat = defaults.string(forKey: Key.timeFormat).flatMap(TimeFormat.init(rawValue:))
            ?? (localeUses12Hour ? .twelveHour : .twentyFourHour)
        storedUnits = defaults.string(forKey: Key.units).flatMap(UnitSystem.init(rawValue:))
            ?? (Locale.current.measurementSystem == .us ? .imperial : .metric)
        // Haptics default off: no vibration motor use unless the user asks for it.
        storedHaptics = defaults.object(forKey: Key.haptics) as? Bool ?? false
        storedAnimation = defaults.string(forKey: Key.animation).flatMap(AnimationMode.init(rawValue:)) ?? .minimal
        storedShowDate = defaults.object(forKey: Key.showDate) as? Bool ?? true
        storedShowHeartRate = defaults.object(forKey: Key.showHeartRate) as? Bool ?? true
        storedShowBattery = defaults.object(forKey: Key.showBattery) as? Bool ?? true

        if let saved = defaults.stringArray(forKey: Key.metricOrder) {
            let order = saved.compactMap(HealthMetric.init(rawValue:))
            // Metrics added in a later version go to the end.
            storedMetricOrder = order + HealthMetric.defaultOrder.filter { !order.contains($0) }
        } else {
            storedMetricOrder = HealthMetric.defaultOrder
        }
        if let saved = defaults.stringArray(forKey: Key.enabledMetrics) {
            storedEnabledMetrics = Set(saved.compactMap(HealthMetric.init(rawValue:)))
        } else {
            storedEnabledMetrics = HealthMetric.defaultEnabled
        }
    }

    var timeFormat: TimeFormat {
        get { storedTimeFormat }
        set { storedTimeFormat = newValue; defaults.set(newValue.rawValue, forKey: Key.timeFormat) }
    }

    var units: UnitSystem {
        get { storedUnits }
        set { storedUnits = newValue; defaults.set(newValue.rawValue, forKey: Key.units) }
    }

    var hapticsEnabled: Bool {
        get { storedHaptics }
        set { storedHaptics = newValue; defaults.set(newValue, forKey: Key.haptics) }
    }

    var animationMode: AnimationMode {
        get { storedAnimation }
        set { storedAnimation = newValue; defaults.set(newValue.rawValue, forKey: Key.animation) }
    }

    var showDate: Bool {
        get { storedShowDate }
        set { storedShowDate = newValue; defaults.set(newValue, forKey: Key.showDate) }
    }

    var showHeartRate: Bool {
        get { storedShowHeartRate }
        set { storedShowHeartRate = newValue; defaults.set(newValue, forKey: Key.showHeartRate) }
    }

    var showBattery: Bool {
        get { storedShowBattery }
        set { storedShowBattery = newValue; defaults.set(newValue, forKey: Key.showBattery) }
    }

    /// Order of every metric, enabled or not.
    var metricOrder: [HealthMetric] {
        get { storedMetricOrder }
        set { storedMetricOrder = newValue; defaults.set(newValue.map(\.rawValue), forKey: Key.metricOrder) }
    }

    var enabledMetrics: Set<HealthMetric> {
        get { storedEnabledMetrics }
        set { storedEnabledMetrics = newValue; defaults.set(newValue.map(\.rawValue), forKey: Key.enabledMetrics) }
    }

    /// Cards on the crown carousel, in the user's order.
    var visibleMetrics: [HealthMetric] {
        metricOrder.filter(enabledMetrics.contains)
    }

    /// Everything HealthKit needs to be asked about. Disabled metrics are never queried.
    var trackedMetrics: [HealthMetric] {
        var metrics = visibleMetrics
        if showHeartRate && !metrics.contains(.heartRate) { metrics.append(.heartRate) }
        return metrics
    }

    func isEnabled(_ metric: HealthMetric) -> Bool {
        enabledMetrics.contains(metric)
    }

    func setEnabled(_ metric: HealthMetric, _ enabled: Bool) {
        if enabled { enabledMetrics.insert(metric) } else { enabledMetrics.remove(metric) }
    }

    /// Moves an enabled metric up (-1) or down (+1) past its visible neighbour.
    func move(_ metric: HealthMetric, by offset: Int) {
        let visible = visibleMetrics
        guard let index = visible.firstIndex(of: metric), visible.indices.contains(index + offset) else { return }
        var order = metricOrder
        guard
            let from = order.firstIndex(of: metric),
            let to = order.firstIndex(of: visible[index + offset])
        else { return }
        order.swapAt(from, to)
        metricOrder = order
    }
}
