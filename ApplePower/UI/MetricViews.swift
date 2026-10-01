import SwiftUI

/// One crown page: label, big number, unit, and a subtle last-updated stamp.
struct MetricCardView: View {
    let metric: HealthMetric

    @Environment(AppSettings.self) private var settings
    @Environment(DashboardStore.self) private var dashboard

    var body: some View {
        VStack(spacing: 2) {
            Text(metric.title)
                .font(Theme.label)
                .tracking(1.2)
                .foregroundStyle(Theme.secondary)

            if let reading = dashboard.reading(for: metric) {
                let formatted = MetricFormatter.format(metric, reading.value, units: settings.units)
                Text(formatted.value)
                    .font(Theme.numeral(54))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(formatted.unit)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                if let date = reading.sampleDate {
                    Text(DisplayFormat.lastUpdated(date, settings.timeFormat))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Tapped from a card. History is queried only here, only for the selected range, and cached for a few minutes.
struct MetricDetailView: View {
    let metric: HealthMetric

    @Environment(AppSettings.self) private var settings
    @Environment(DashboardStore.self) private var dashboard

    @State private var range: HistoryRange = .today
    @State private var history: MetricHistory?
    @State private var restingHeartRate: MetricReading?

    private var reading: MetricReading? { dashboard.reading(for: metric) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                RangePicker(selection: $range)
                if let history, history.range == range {
                    facts(for: history)
                    if history.points.count > 1 {
                        MiniBarChart(values: history.points.map(\.value), fromZero: metric.aggregation != .latest)
                            .frame(height: 36)
                    }
                }
                if let date = reading?.sampleDate {
                    FactRow(label: "LAST UPDATED", value: DisplayFormat.lastUpdated(date, settings.timeFormat))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(metric.title)
        .background(Theme.background.ignoresSafeArea())
        .task(id: range) {
            history = await dashboard.history(for: metric, range: range)
        }
        .task {
            if metric == .heartRate {
                restingHeartRate = await dashboard.companionReading(for: .restingHeartRate)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(headlineLabel)
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiary)
            if let reading {
                let formatted = MetricFormatter.format(metric, reading.value, units: settings.units)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatted.value)
                        .font(Theme.numeral(40))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(formatted.unit)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var headlineLabel: String {
        switch metric.aggregation {
        case .latest: return "LATEST"
        case .dailyTotal: return "TODAY"
        case .nightly: return "LAST NIGHT"
        }
    }

    @ViewBuilder
    private func facts(for history: MetricHistory) -> some View {
        let units = settings.units
        switch metric.aggregation {
        case .latest:
            if metric == .heartRate, let restingHeartRate {
                FactRow(label: "RESTING", value: format(restingHeartRate.value, as: .restingHeartRate))
            }
            if let average = history.average {
                FactRow(label: "AVERAGE", value: format(average))
            }
            if let low = history.minimum, let high = history.maximum {
                FactRow(label: history.range.rangeLabel, value: MetricFormatter.range(metric, low: low, high: high, units: units))
            }
        case .dailyTotal:
            if history.range != .today, let total = history.total {
                FactRow(label: "TOTAL", value: format(total))
            }
            if let average = history.average {
                FactRow(label: "DAILY AVG", value: format(average))
            }
        case .nightly:
            if let average = history.average {
                FactRow(label: "AVG / NIGHT", value: format(average))
            }
            if let low = history.minimum, let high = history.maximum {
                FactRow(label: "RANGE", value: MetricFormatter.range(metric, low: low, high: high, units: units))
            }
        }
    }

    private func format(_ value: Double, as other: HealthMetric? = nil) -> String {
        MetricFormatter.format(other ?? metric, value, units: settings.units).inline
    }
}

struct RangePicker: View {
    @Binding var selection: HistoryRange

    var body: some View {
        HStack(spacing: 10) {
            ForEach(HistoryRange.allCases) { range in
                Button(range.label) { selection = range }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(range == selection ? Theme.primary : Theme.tertiary)
                    .accessibilityAddTraits(range == selection ? .isSelected : [])
            }
        }
    }
}

struct FactRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
            Text(value)
                .font(.system(size: 17).monospacedDigit())
                .foregroundStyle(Theme.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Static grey bars drawn as a single path in one Canvas: no axes, no animation, no per-bar views.
struct MiniBarChart: View {
    let values: [Double?]
    /// Totals start at zero; for rates like heart rate the bars are scaled between min and max so variation is visible.
    let fromZero: Bool

    var body: some View {
        Canvas { context, size in
            let present = values.compactMap { $0 }
            guard let high = present.max(), high > 0, !values.isEmpty else { return }
            let low = fromZero ? 0 : (present.min() ?? 0)
            let span = max(high - low, .ulpOfOne)
            let slot = size.width / CGFloat(values.count)
            let barWidth = max(1, slot * 0.6)

            var path = Path()
            for (index, value) in values.enumerated() {
                guard let value, value > 0 else { continue }
                let fraction = fromZero ? value / high : 0.2 + 0.8 * (value - low) / span
                let height = max(1, size.height * CGFloat(fraction))
                path.addRect(CGRect(
                    x: CGFloat(index) * slot + (slot - barWidth) / 2,
                    y: size.height - height,
                    width: barWidth,
                    height: height
                ))
            }
            context.fill(path, with: .color(Theme.secondary))
        }
        .accessibilityHidden(true)
    }
}
