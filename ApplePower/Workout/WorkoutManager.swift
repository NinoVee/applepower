import Foundation
import HealthKit
import Observation
import WatchKit

enum WorkoutActivity: String, CaseIterable, Identifiable {
    case walk
    case run
    case cycle
    case strength

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walk: return "WALK"
        case .run: return "RUN"
        case .cycle: return "CYCLE"
        case .strength: return "STRENGTH"
        }
    }

    var activityType: HKWorkoutActivityType {
        switch self {
        case .walk: return .walking
        case .run: return .running
        case .cycle: return .cycling
        case .strength: return .traditionalStrengthTraining
        }
    }

    /// Outdoor sessions let watchOS use GPS for distance. Strength is indoor, so no GPS at all.
    var locationType: HKWorkoutSessionLocationType {
        self == .strength ? .indoor : .outdoor
    }

    var tracksDistance: Bool { self != .strength }
}

struct WorkoutSummary: Equatable {
    var activity: WorkoutActivity
    var duration: TimeInterval
    var distanceMeters: Double?
    var energyKcal: Double?
    var averageHeartRate: Double?
    var saved: Bool
}

/// The only place the app asks for continuous sensor sampling, and only between the user tapping START and END.
@MainActor
@Observable
final class WorkoutManager: NSObject {
    enum Phase: Equatable {
        case idle
        case starting
        case running
        case paused
        case ending
        case summary(WorkoutSummary)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var activity: WorkoutActivity?
    private(set) var startDate: Date?
    private(set) var heartRate: Double?
    private(set) var distanceMeters: Double?
    private(set) var energyKcal: Double?

    @ObservationIgnored private let store: HKHealthStore
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var hapticsEnabled = false

    init(store: HKHealthStore = .shared) {
        self.store = store
        super.init()
    }

    /// True whenever the workout UI should replace the dashboard (including the summary screen).
    var isActive: Bool { phase != .idle }

    var isPaused: Bool { phase == .paused }

    func elapsedTime(at date: Date) -> TimeInterval {
        builder?.elapsedTime(at: date) ?? 0
    }

    func start(_ activity: WorkoutActivity, hapticsEnabled: Bool) async {
        guard phase == .idle else { return }
        self.activity = activity
        self.hapticsEnabled = hapticsEnabled
        phase = .starting

        do {
            try await requestAuthorization()

            let configuration = HKWorkoutConfiguration()
            configuration.activityType = activity.activityType
            configuration.locationType = activity.locationType

            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            startDate = start
            phase = .running
            playHaptic(.start)
        } catch {
            session?.end()
            session = nil
            builder = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func pause() {
        session?.pause()
    }

    func resume() {
        session?.resume()
    }

    func end() {
        guard let session else { return }
        phase = .ending
        session.end()
    }

    /// Leaves the summary and returns the app to its low-power dashboard.
    func reset() {
        phase = .idle
        activity = nil
        startDate = nil
        heartRate = nil
        distanceMeters = nil
        energyKcal = nil
        session = nil
        builder = nil
    }

    // MARK: Private

    /// Asked the first time a workout starts, never at launch.
    private func requestAuthorization() async throws {
        let share: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
        ]
        let read: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
        ]
        try await store.requestAuthorization(toShare: share, read: read)
    }

    private func sessionDidChange(to state: HKWorkoutSessionState, at date: Date) {
        switch state {
        case .running:
            if phase == .paused { phase = .running }
        case .paused:
            if phase == .running { phase = .paused }
        case .ended:
            Task { await finish(at: date) }
        default:
            break
        }
    }

    private func finish(at date: Date) async {
        guard let builder, let activity else { return }
        var saved = false
        do {
            try await builder.endCollection(at: date)
            saved = try await builder.finishWorkout() != nil
        } catch {
            saved = false
        }
        let averageHeartRate = builder.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: .bpm)
        let summary = WorkoutSummary(
            activity: activity,
            duration: builder.elapsedTime,
            distanceMeters: activity.tracksDistance ? distanceMeters : nil,
            energyKcal: energyKcal,
            averageHeartRate: averageHeartRate,
            saved: saved
        )
        session = nil
        self.builder = nil
        phase = .summary(summary)
        playHaptic(.stop)
    }

    private func apply(heartRate: Double?, distance: Double?, energy: Double?) {
        // Assign only on change so the live view redraws as little as possible.
        if let heartRate, heartRate != self.heartRate { self.heartRate = heartRate }
        if let distance, distance != distanceMeters { distanceMeters = distance }
        if let energy, energy != energyKcal { energyKcal = energy }
    }

    private func fail(_ error: Error) {
        session = nil
        builder = nil
        phase = .failed(error.localizedDescription)
    }

    private func playHaptic(_ type: WKHapticType) {
        if hapticsEnabled { WKInterfaceDevice.current().play(type) }
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in self.sessionDidChange(to: toState, at: date) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.fail(error) }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        var heartRate: Double?
        var distance: Double?
        var energy: Double?
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType, let statistics = workoutBuilder.statistics(for: quantityType) else { continue }
            switch HKQuantityTypeIdentifier(rawValue: quantityType.identifier) {
            case .heartRate:
                heartRate = statistics.mostRecentQuantity()?.doubleValue(for: .bpm)
            case .activeEnergyBurned:
                energy = statistics.sumQuantity()?.doubleValue(for: .kilocalorie())
            case .distanceWalkingRunning, .distanceCycling:
                distance = statistics.sumQuantity()?.doubleValue(for: .meter())
            default:
                break
            }
        }
        let update = (heartRate: heartRate, distance: distance, energy: energy)
        Task { @MainActor in self.apply(heartRate: update.heartRate, distance: update.distance, energy: update.energy) }
    }
}
