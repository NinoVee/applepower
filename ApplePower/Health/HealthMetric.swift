import HealthKit

extension HKHealthStore {
    /// Apple recommends a single store per app; both the dashboard and workouts share it.
    static let shared = HKHealthStore()
}

extension HKUnit {
    static let bpm = HKUnit.count().unitDivided(by: .minute())
    static let vo2Max = HKUnit(from: "ml/kg*min")
}

/// Every measurement the dashboard can show.
/// Raw values are persisted in settings and the cache, so don't rename cases.
enum HealthMetric: String, CaseIterable, Codable, Identifiable, Hashable {
    case heartRate
    case restingHeartRate
    case walkingHeartRateAverage
    case heartRateVariability
    case bloodOxygen
    case respiratoryRate
    case wristTemperature
    case steps
    case walkingRunningDistance
    case cyclingDistance
    case activeEnergy
    case exerciseMinutes
    case standHours
    case flightsClimbed
    case workouts
    case sleep
    case vo2Max

    var id: String { rawValue }

    /// Where a metric's value comes from in HealthKit. Values are always stored in the canonical unit given here
    /// and converted for display, so a units change never invalidates the cache.
    enum Source {
        case discrete(HKQuantityTypeIdentifier, HKUnit)
        case cumulative(HKQuantityTypeIdentifier, HKUnit)
        case standHours
        case workouts
        case sleep
    }

    /// How the headline number is derived.
    enum Aggregation {
        /// Most recent sample (heart rate, HRV, SpO2 ...).
        case latest
        /// Sum or count since midnight (steps, energy, stand hours ...).
        case dailyTotal
        /// Time asleep last night.
        case nightly
    }

    static let defaultOrder: [HealthMetric] = [
        .heartRate, .steps, .activeEnergy, .heartRateVariability, .bloodOxygen, .restingHeartRate,
        .exerciseMinutes, .standHours, .walkingRunningDistance, .sleep, .respiratoryRate, .wristTemperature,
        .walkingHeartRateAverage, .flightsClimbed, .workouts, .vo2Max, .cyclingDistance,
    ]

    /// Enabled on first launch. Everything else is opt-in so it is never queried unless the user wants it.
    static let defaultEnabled: Set<HealthMetric> = [
        .heartRate, .steps, .activeEnergy, .heartRateVariability, .bloodOxygen, .restingHeartRate,
        .exerciseMinutes, .sleep,
    ]

    var source: Source {
        switch self {
        case .heartRate: return .discrete(.heartRate, .bpm)
        case .restingHeartRate: return .discrete(.restingHeartRate, .bpm)
        case .walkingHeartRateAverage: return .discrete(.walkingHeartRateAverage, .bpm)
        case .heartRateVariability: return .discrete(.heartRateVariabilitySDNN, .secondUnit(with: .milli))
        case .bloodOxygen: return .discrete(.oxygenSaturation, .percent())
        case .respiratoryRate: return .discrete(.respiratoryRate, .bpm)
        case .wristTemperature: return .discrete(.appleSleepingWristTemperature, .degreeCelsius())
        case .vo2Max: return .discrete(.vo2Max, .vo2Max)
        case .steps: return .cumulative(.stepCount, .count())
        case .walkingRunningDistance: return .cumulative(.distanceWalkingRunning, .meter())
        case .cyclingDistance: return .cumulative(.distanceCycling, .meter())
        case .activeEnergy: return .cumulative(.activeEnergyBurned, .kilocalorie())
        case .exerciseMinutes: return .cumulative(.appleExerciseTime, .minute())
        case .flightsClimbed: return .cumulative(.flightsClimbed, .count())
        case .standHours: return .standHours
        case .workouts: return .workouts
        case .sleep: return .sleep
        }
    }

    var aggregation: Aggregation {
        switch source {
        case .discrete: return .latest
        case .cumulative, .standHours, .workouts: return .dailyTotal
        case .sleep: return .nightly
        }
    }

    var sampleType: HKSampleType {
        switch source {
        case .discrete(let identifier, _), .cumulative(let identifier, _):
            return HKQuantityType(identifier)
        case .standHours:
            return HKCategoryType(.appleStandHour)
        case .workouts:
            return HKObjectType.workoutType()
        case .sleep:
            return HKCategoryType(.sleepAnalysis)
        }
    }

    /// Metrics whose values appear on this metric's detail screen and are authorized alongside it.
    var companions: [HealthMetric] {
        self == .heartRate ? [.restingHeartRate] : []
    }

    var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [sampleType]
        for companion in companions { types.insert(companion.sampleType) }
        return types
    }

    /// Minimum age before a cached value is re-queried when the app becomes active.
    /// Slow-moving physiology is checked rarely; activity counters more often.
    var refreshInterval: TimeInterval {
        switch self {
        case .heartRate: return 2 * 60
        case .steps, .activeEnergy, .exerciseMinutes, .walkingRunningDistance: return 5 * 60
        case .cyclingDistance, .standHours, .flightsClimbed: return 10 * 60
        case .workouts: return 15 * 60
        case .heartRateVariability, .bloodOxygen: return 30 * 60
        case .restingHeartRate, .walkingHeartRateAverage, .respiratoryRate, .sleep: return 60 * 60
        case .wristTemperature, .vo2Max: return 6 * 60 * 60
        }
    }

    /// Daily totals belong to a calendar day, so a value cached yesterday is always stale.
    var resetsDaily: Bool { aggregation != .latest }

    var title: String {
        switch self {
        case .heartRate: return "HEART RATE"
        case .restingHeartRate: return "RESTING HR"
        case .walkingHeartRateAverage: return "WALKING HR"
        case .heartRateVariability: return "HRV"
        case .bloodOxygen: return "BLOOD OXYGEN"
        case .respiratoryRate: return "RESPIRATORY"
        case .wristTemperature: return "WRIST TEMP"
        case .steps: return "STEPS"
        case .walkingRunningDistance: return "DISTANCE"
        case .cyclingDistance: return "CYCLING"
        case .activeEnergy: return "ACTIVE ENERGY"
        case .exerciseMinutes: return "EXERCISE"
        case .standHours: return "STAND"
        case .flightsClimbed: return "FLIGHTS"
        case .workouts: return "WORKOUTS"
        case .sleep: return "SLEEP"
        case .vo2Max: return "VO₂ MAX"
        }
    }
}
