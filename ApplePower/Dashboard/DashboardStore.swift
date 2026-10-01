import Foundation
import HealthKit
import Observation

/// Owns the values the UI shows and decides when HealthKit is worth asking again.
///
/// Refresh policy (battery first):
/// - Values render from the on-disk cache immediately; no query is needed to draw the screen.
/// - When the app becomes active, only metrics older than their `refreshInterval` are re-queried.
/// - While active, HealthKit observer queries push "new data exists" events; those are coalesced and refreshed together.
/// - When the app goes inactive (wrist down / Always-On) every observer is stopped. No background refresh is scheduled.
@MainActor
@Observable
final class DashboardStore {
    private(set) var readings: [HealthMetric: MetricReading] = [:]

    @ObservationIgnored private let service: HealthDataService
    @ObservationIgnored private let cache: MetricCache
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar = Calendar.autoupdatingCurrent

    @ObservationIgnored private var lastFetch: [HealthMetric: Date] = [:]
    @ObservationIgnored private var emptyChecks: [HealthMetric: Date] = [:]
    @ObservationIgnored private var requestedMetrics: Set<HealthMetric>
    @ObservationIgnored private var tracked: [HealthMetric] = []
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var inFlight: Set<HealthMetric> = []

    @ObservationIgnored private var observers: [HKObserverQuery] = []
    @ObservationIgnored private var observersStartedAt = Date.distantPast
    @ObservationIgnored private var pendingUpdates: Set<HealthMetric> = []
    @ObservationIgnored private var pendingTask: Task<Void, Never>?

    @ObservationIgnored private var historyCache: [HistoryKey: CachedHistory] = [:]

    private static let requestedKey = "healthkit.requestedMetrics"
    /// Metrics that returned no data are re-checked this rarely (e.g. after the user grants access later).
    private static let emptyRecheckInterval: TimeInterval = 6 * 60 * 60
    /// New-data events arriving within this window are fetched in one batch.
    private static let observerCoalescingDelay: Duration = .seconds(10)
    /// HealthKit fires each observer once on start; that is covered by the activation refresh.
    private static let observerStartupGrace: TimeInterval = 2
    private static let historyLifetime: TimeInterval = 10 * 60

    private struct HistoryKey: Hashable {
        var metric: HealthMetric
        var range: HistoryRange
    }

    private struct CachedHistory {
        var history: MetricHistory
        var fetchedAt: Date
    }

    init(service: HealthDataService = HealthDataService(), cache: MetricCache = MetricCache(), defaults: UserDefaults = .standard) {
        self.service = service
        self.cache = cache
        self.defaults = defaults
        requestedMetrics = Set((defaults.stringArray(forKey: Self.requestedKey) ?? []).compactMap(HealthMetric.init(rawValue:)))

        let snapshot = cache.load()
        readings = snapshot.readings
        lastFetch = snapshot.lastFetch
        emptyChecks = snapshot.emptyChecks
    }

    func reading(for metric: HealthMetric) -> MetricReading? {
        readings[metric]
    }

    // MARK: Lifecycle

    /// Called on launch and whenever the set of metrics the UI needs changes.
    func track(_ metrics: [HealthMetric]) async {
        tracked = metrics
        await requestAuthorizationIfNeeded(for: metrics)
        if isActive { restartObservers() }
        await refresh(metrics)
    }

    func sceneDidBecomeActive() async {
        guard !isActive else { return }
        isActive = true
        restartObservers()
        await refresh(tracked)
    }

    func sceneDidResignActive() {
        guard isActive else { return }
        isActive = false
        stopObservers()
        pendingTask?.cancel()
        pendingTask = nil
        pendingUpdates.removeAll()
        historyCache.removeAll()
    }

    /// After a workout the activity totals have certainly changed.
    func refreshAfterWorkout() async {
        await refresh(tracked, force: true)
    }

    /// Fetches a metric that isn't on the dashboard but is shown on another metric's detail screen.
    func companionReading(for metric: HealthMetric) async -> MetricReading? {
        await refresh([metric])
        return readings[metric]
    }

    func clearCache() async {
        readings = [:]
        lastFetch = [:]
        emptyChecks = [:]
        historyCache = [:]
        cache.clear()
        await refresh(tracked, force: true)
    }

    // MARK: History

    func history(for metric: HealthMetric, range: HistoryRange) async -> MetricHistory? {
        let key = HistoryKey(metric: metric, range: range)
        if let cached = historyCache[key], Date().timeIntervalSince(cached.fetchedAt) < Self.historyLifetime {
            return cached.history
        }
        guard service.isHealthDataAvailable, let history = try? await service.history(for: metric, range: range) else {
            return nil
        }
        historyCache[key] = CachedHistory(history: history, fetchedAt: Date())
        return history
    }

    // MARK: Refreshing

    func refresh(_ metrics: [HealthMetric], force: Bool = false) async {
        guard service.isHealthDataAvailable else { return }
        let now = Date()
        // Never query before authorization was requested: an early empty result would hide the card for hours.
        let due = Set(metrics).filter {
            requestedMetrics.contains($0) && !inFlight.contains($0) && (force || isStale($0, now: now))
        }
        guard !due.isEmpty else { return }

        inFlight.formUnion(due)
        let service = self.service
        let results = await withTaskGroup(of: (HealthMetric, MetricReading?, Bool).self) { group in
            for metric in due {
                group.addTask {
                    do {
                        return (metric, try await service.fetchReading(for: metric, now: now), true)
                    } catch {
                        // Typically the watch is locked and HealthKit is unreadable; keep the cached value.
                        return (metric, nil, false)
                    }
                }
            }
            var collected: [(HealthMetric, MetricReading?, Bool)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        inFlight.subtract(due)

        var changed = false
        for (metric, reading, succeeded) in results where succeeded {
            lastFetch[metric] = now
            apply(reading, to: metric, at: now)
            changed = true
        }
        if changed { persist() }
    }

    private func isStale(_ metric: HealthMetric, now: Date) -> Bool {
        if readings[metric] == nil {
            guard let checked = emptyChecks[metric] else { return true }
            return now.timeIntervalSince(checked) >= Self.emptyRecheckInterval
        }
        guard let fetched = lastFetch[metric] else { return true }
        if metric.resetsDaily && !calendar.isDate(fetched, inSameDayAs: now) { return true }
        return now.timeIntervalSince(fetched) >= metric.refreshInterval
    }

    /// Only assigns when something visible changed, so unchanged values don't trigger SwiftUI redraws.
    private func apply(_ reading: MetricReading?, to metric: HealthMetric, at now: Date) {
        guard var reading else {
            emptyChecks[metric] = now
            if readings[metric] != nil { readings[metric] = nil }
            return
        }
        emptyChecks[metric] = nil
        let previous = readings[metric]
        if reading.sampleDate == nil {
            // Totals have no single sample date; "last updated" is when the number last changed.
            reading.sampleDate = previous?.value == reading.value ? (previous?.sampleDate ?? now) : now
        }
        if previous != reading { readings[metric] = reading }
    }

    private func persist() {
        cache.save(CacheSnapshot(readings: readings, lastFetch: lastFetch, emptyChecks: emptyChecks))
    }

    private func requestAuthorizationIfNeeded(for metrics: [HealthMetric]) async {
        guard service.isHealthDataAvailable else { return }
        let missing = metrics.filter { !requestedMetrics.contains($0) }
        guard !missing.isEmpty else { return }
        do {
            try await service.requestReadAuthorization(for: missing)
        } catch {
            return
        }
        // HealthKit never reveals whether reading was allowed; denied types simply return no data and stay hidden.
        let granted = missing + missing.flatMap(\.companions)
        requestedMetrics.formUnion(granted)
        for metric in granted { emptyChecks[metric] = nil }
        defaults.set(requestedMetrics.map(\.rawValue), forKey: Self.requestedKey)
    }

    // MARK: Observers

    private func restartObservers() {
        stopObservers()
        let metrics = tracked.filter(requestedMetrics.contains)
        guard service.isHealthDataAvailable, !metrics.isEmpty else { return }
        observersStartedAt = Date()
        // The store lives as long as the app and every query is stopped on resign, so a strong capture is fine.
        observers = service.startObservers(for: metrics) { metric in
            Task { @MainActor in self.handleObserverUpdate(metric) }
        }
    }

    private func stopObservers() {
        service.stopObservers(observers)
        observers = []
    }

    private func handleObserverUpdate(_ metric: HealthMetric) {
        guard isActive, Date().timeIntervalSince(observersStartedAt) > Self.observerStartupGrace else { return }
        pendingUpdates.insert(metric)
        guard pendingTask == nil else { return }
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.observerCoalescingDelay)
            guard let self, !Task.isCancelled else { return }
            let metrics = Array(self.pendingUpdates)
            self.pendingUpdates.removeAll()
            self.pendingTask = nil
            await self.refresh(metrics, force: true)
        }
    }
}
