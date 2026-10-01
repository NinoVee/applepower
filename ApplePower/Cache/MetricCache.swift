import Foundation

struct CacheSnapshot {
    var readings: [HealthMetric: MetricReading] = [:]
    /// When each metric was last successfully queried.
    var lastFetch: [HealthMetric: Date] = [:]
    /// When a metric last came back with no data at all; it stays hidden and is re-checked rarely.
    var emptyChecks: [HealthMetric: Date] = [:]
}

/// Persists the latest values as a small JSON file so the dashboard renders instantly on launch
/// without touching HealthKit. The file stays on the watch: it is file-protected and excluded from backups.
struct MetricCache {
    private struct Stored: Codable {
        var version: Int
        var readings: [String: MetricReading]
        var lastFetch: [String: Date]
        var emptyChecks: [String: Date]
    }

    private static let version = 1
    private let url: URL

    init(fileName: String = "metric-cache.json") {
        let directory = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        url = directory.appendingPathComponent(fileName)
    }

    func load() -> CacheSnapshot {
        guard
            let data = try? Data(contentsOf: url),
            let stored = try? JSONDecoder().decode(Stored.self, from: data),
            stored.version == Self.version
        else { return CacheSnapshot() }

        return CacheSnapshot(
            readings: Self.metricKeyed(stored.readings),
            lastFetch: Self.metricKeyed(stored.lastFetch),
            emptyChecks: Self.metricKeyed(stored.emptyChecks)
        )
    }

    func save(_ snapshot: CacheSnapshot) {
        let stored = Stored(
            version: Self.version,
            readings: Self.stringKeyed(snapshot.readings),
            lastFetch: Self.stringKeyed(snapshot.lastFetch),
            emptyChecks: Self.stringKeyed(snapshot.emptyChecks)
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var fileURL = url
            try fileURL.setResourceValues(values)
        } catch {
            // A failed cache write only costs an extra query next launch.
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    private static func metricKeyed<Value>(_ dictionary: [String: Value]) -> [HealthMetric: Value] {
        var result: [HealthMetric: Value] = [:]
        for (key, value) in dictionary {
            if let metric = HealthMetric(rawValue: key) { result[metric] = value }
        }
        return result
    }

    private static func stringKeyed<Value>(_ dictionary: [HealthMetric: Value]) -> [String: Value] {
        Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key.rawValue, $0.value) })
    }
}
