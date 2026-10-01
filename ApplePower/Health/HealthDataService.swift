import HealthKit

/// Thin, stateless wrapper around HealthKit queries. All reads are one-shot async queries;
/// nothing here keeps a sensor or a long-running query alive except the observers the caller explicitly starts.
final class HealthDataService: @unchecked Sendable {
    private let store: HKHealthStore
    private let calendar = Calendar.autoupdatingCurrent

    init(store: HKHealthStore = .shared) {
        self.store = store
    }

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Requests read access for exactly the metrics passed in, so the user is only asked about what they enabled.
    func requestReadAuthorization(for metrics: [HealthMetric]) async throws {
        let types = metrics.reduce(into: Set<HKObjectType>()) { $0.formUnion($1.readTypes) }
        guard !types.isEmpty else { return }
        try await store.requestAuthorization(toShare: [], read: types)
    }

    // MARK: Headline values

    /// The value shown on a metric's card, or `nil` if HealthKit has never had data for it
    /// (unsupported sensor, read access denied, or simply never recorded) so the card can be hidden.
    func fetchReading(for metric: HealthMetric, now: Date = .now) async throws -> MetricReading? {
        let today = HKQuery.predicateForSamples(withStart: calendar.startOfDay(for: now), end: now)

        switch metric.source {
        case let .discrete(identifier, unit):
            guard let sample = try await latestSample(.quantitySample(type: HKQuantityType(identifier))) else { return nil }
            return MetricReading(value: sample.quantity.doubleValue(for: unit), sampleDate: sample.endDate)

        case let .cumulative(identifier, unit):
            // Statistics queries de-duplicate overlapping sources (e.g. iPhone and watch both counting steps).
            let predicate = HKSamplePredicate.quantitySample(type: HKQuantityType(identifier), predicate: today)
            let statistics = try await HKStatisticsQueryDescriptor(predicate: predicate, options: .cumulativeSum).result(for: store)
            if let sum = statistics?.sumQuantity() {
                return MetricReading(value: sum.doubleValue(for: unit))
            }
            return try await zeroIfEverRecorded(metric)

        case .standHours:
            let samples = try await samples(.categorySample(type: HKCategoryType(.appleStandHour), predicate: today))
            guard !samples.isEmpty else { return try await zeroIfEverRecorded(metric) }
            let hours = Set(samples.filter(Self.isStood).map { calendar.component(.hour, from: $0.startDate) })
            return MetricReading(value: Double(hours.count))

        case .workouts:
            let workouts = try await samples(.workout(today))
            guard let latest = workouts.map(\.endDate).max() else { return try await zeroIfEverRecorded(metric) }
            return MetricReading(value: Double(workouts.count), sampleDate: latest)

        case .sleep:
            let tonight = calendar.startOfDay(for: now)
            let windowStart = calendar.date(byAdding: .hour, value: -Self.nightOffsetHours, to: tonight) ?? tonight
            let nights = try await sleepByNight(from: windowStart, to: now)
            guard let asleep = nights[tonight] else { return try await zeroIfEverRecorded(metric) }
            return MetricReading(value: asleep)
        }
    }

    // MARK: History

    /// Data for the detail screen. Only run when the user opens a detail view.
    func history(for metric: HealthMetric, range: HistoryRange, now: Date = .now) async throws -> MetricHistory {
        let start = range.start(relativeTo: now, calendar: calendar)
        let window = HKQuery.predicateForSamples(withStart: start, end: now)

        switch metric.source {
        case let .discrete(identifier, unit):
            let predicate = HKSamplePredicate.quantitySample(type: HKQuantityType(identifier), predicate: window)
            let statistics = try await HKStatisticsQueryDescriptor(
                predicate: predicate,
                options: [.discreteAverage, .discreteMin, .discreteMax]
            ).result(for: store)
            let collection = try await HKStatisticsCollectionQueryDescriptor(
                predicate: predicate,
                options: .discreteAverage,
                anchorDate: start,
                intervalComponents: range.bucket
            ).result(for: store)
            return MetricHistory(
                range: range,
                points: points(in: collection, from: start, to: now) { $0.averageQuantity()?.doubleValue(for: unit) },
                average: statistics?.averageQuantity()?.doubleValue(for: unit),
                minimum: statistics?.minimumQuantity()?.doubleValue(for: unit),
                maximum: statistics?.maximumQuantity()?.doubleValue(for: unit)
            )

        case let .cumulative(identifier, unit):
            let predicate = HKSamplePredicate.quantitySample(type: HKQuantityType(identifier), predicate: window)
            let collection = try await HKStatisticsCollectionQueryDescriptor(
                predicate: predicate,
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: range.bucket
            ).result(for: store)
            let buckets = points(in: collection, from: start, to: now) { $0.sumQuantity()?.doubleValue(for: unit) }
            let total = buckets.compactMap(\.value).reduce(0, +)
            return MetricHistory(
                range: range,
                points: buckets,
                total: total,
                average: range == .today ? nil : total / Double(range.days)
            )

        case .standHours:
            let samples = try await samples(.categorySample(type: HKCategoryType(.appleStandHour), predicate: window))
            var hoursByDay: [Date: Set<Int>] = [:]
            for sample in samples where Self.isStood(sample) {
                hoursByDay[calendar.startOfDay(for: sample.startDate), default: []]
                    .insert(calendar.component(.hour, from: sample.startDate))
            }
            return dailyHistory(range: range, from: start, to: now) { Double(hoursByDay[$0]?.count ?? 0) }

        case .workouts:
            let workouts = try await samples(.workout(window))
            var countByDay: [Date: Int] = [:]
            for workout in workouts {
                countByDay[calendar.startOfDay(for: workout.startDate), default: 0] += 1
            }
            return dailyHistory(range: range, from: start, to: now) { Double(countByDay[$0] ?? 0) }

        case .sleep:
            let windowStart = calendar.date(byAdding: .hour, value: -Self.nightOffsetHours, to: start) ?? start
            let nights = try await sleepByNight(from: windowStart, to: now)
            if range == .today {
                return MetricHistory(range: range, total: nights[calendar.startOfDay(for: now)])
            }
            let buckets = dayStarts(from: start, through: now).map { HistoryPoint(date: $0, value: nights[$0]) }
            let recorded = buckets.compactMap(\.value).filter { $0 > 0 }
            return MetricHistory(
                range: range,
                points: buckets,
                average: recorded.isEmpty ? nil : recorded.reduce(0, +) / Double(recorded.count),
                minimum: recorded.min(),
                maximum: recorded.max()
            )
        }
    }

    // MARK: Observers

    /// Event-driven updates: HealthKit calls back only when new samples are saved. The caller starts these
    /// while the app is in the foreground and stops them as soon as it isn't.
    func startObservers(for metrics: [HealthMetric], onUpdate: @escaping @Sendable (HealthMetric) -> Void) -> [HKObserverQuery] {
        metrics.map { metric in
            let query = HKObserverQuery(sampleType: metric.sampleType, predicate: nil) { _, completion, error in
                if error == nil { onUpdate(metric) }
                completion()
            }
            store.execute(query)
            return query
        }
    }

    func stopObservers(_ queries: [HKObserverQuery]) {
        for query in queries { store.stop(query) }
    }

    // MARK: Helpers

    /// Sleep that ends after 18:00 counts toward the following night.
    private static let nightOffsetHours = 6

    private static func isStood(_ sample: HKCategorySample) -> Bool {
        sample.value == HKCategoryValueAppleStandHour.stood.rawValue
    }

    private func nightKey(for end: Date) -> Date {
        calendar.startOfDay(for: end.addingTimeInterval(TimeInterval(Self.nightOffsetHours * 3600)))
    }

    /// Time asleep per night (keyed by the start of the day the night ends on), clamped to the window.
    private func sleepByNight(from start: Date, to end: Date) async throws -> [Date: TimeInterval] {
        let window = HKQuery.predicateForSamples(withStart: start, end: end)
        let samples = try await samples(.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: window))
        let asleepValues = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))

        var intervalsByNight: [Date: [DateInterval]] = [:]
        for sample in samples where asleepValues.contains(sample.value) {
            let lower = max(sample.startDate, start)
            let upper = min(sample.endDate, end)
            guard upper > lower else { continue }
            intervalsByNight[nightKey(for: sample.endDate), default: []].append(DateInterval(start: lower, end: upper))
        }
        return intervalsByNight.mapValues(SleepMath.mergedDuration)
    }

    /// Distinguishes "nothing yet today" (show 0) from "this device/user never records this" (hide the card).
    private func zeroIfEverRecorded(_ metric: HealthMetric) async throws -> MetricReading? {
        try await latestSample(.sample(type: metric.sampleType)) == nil ? nil : MetricReading(value: 0)
    }

    private func latestSample<Sample: HKSample>(_ predicate: HKSamplePredicate<Sample>) async throws -> Sample? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [predicate],
            sortDescriptors: [SortDescriptor(\Sample.endDate, order: .reverse)],
            limit: 1
        )
        return try await descriptor.result(for: store).first
    }

    private func samples<Sample: HKSample>(_ predicate: HKSamplePredicate<Sample>) async throws -> [Sample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [predicate],
            sortDescriptors: [SortDescriptor(\Sample.startDate)]
        )
        return try await descriptor.result(for: store)
    }

    private func points(
        in collection: HKStatisticsCollection,
        from start: Date,
        to end: Date,
        value: @escaping (HKStatistics) -> Double?
    ) -> [HistoryPoint] {
        var result: [HistoryPoint] = []
        collection.enumerateStatistics(from: start, to: end) { statistics, _ in
            result.append(HistoryPoint(date: statistics.startDate, value: value(statistics)))
        }
        return result
    }

    private func dailyHistory(range: HistoryRange, from start: Date, to end: Date, value: (Date) -> Double) -> MetricHistory {
        if range == .today {
            return MetricHistory(range: range, total: value(calendar.startOfDay(for: end)))
        }
        let buckets = dayStarts(from: start, through: end).map { HistoryPoint(date: $0, value: value($0)) }
        let total = buckets.compactMap(\.value).reduce(0, +)
        return MetricHistory(range: range, points: buckets, total: total, average: total / Double(range.days))
    }

    private func dayStarts(from start: Date, through end: Date) -> [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: start)
        while day <= end {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }
}
