import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DashboardStore.self) private var dashboard

    var body: some View {
        @Bindable var settings = settings
        List {
            Section("DISPLAY") {
                ValueRow(label: "TIME", value: settings.timeFormat.label) { settings.timeFormat = settings.timeFormat.next }
                ValueRow(label: "UNITS", value: settings.units.label) { settings.units = settings.units.next }
                ValueRow(label: "ANIMATIONS", value: settings.animationMode.label) { settings.animationMode = settings.animationMode.next }
                Toggle("HAPTICS", isOn: $settings.hapticsEnabled)
            }
            Section("CLOCK") {
                Toggle("DATE", isOn: $settings.showDate)
                Toggle("HEART RATE", isOn: $settings.showHeartRate)
                Toggle("BATTERY", isOn: $settings.showBattery)
            }
            Section("HEALTH") {
                NavigationLink("METRICS") { MetricSelectionView() }
                NavigationLink("ORDER") { MetricOrderView() }
                Button("CLEAR CACHE") { Task { await dashboard.clearCache() } }
            }
            Section {
                Text("Health data stays on this watch. No accounts, network or analytics.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
                    .listRowBackground(Theme.background)
            }
        }
        .tint(Theme.secondary)
        .navigationTitle("SETTINGS")
    }
}

/// Tapping cycles through the options; avoids a separate picker screen for two-choice settings.
struct ValueRow: View {
    let label: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                Spacer()
                Text(value)
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}

/// Disabled metrics are never queried, so turning things off here saves work, not just screen space.
struct MetricSelectionView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        List(settings.metricOrder) { metric in
            Toggle(metric.title, isOn: Binding(
                get: { settings.isEnabled(metric) },
                set: { settings.setEnabled(metric, $0) }
            ))
            .font(.system(size: 15))
        }
        .tint(Theme.secondary)
        .navigationTitle("METRICS")
    }
}

struct MetricOrderView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let metrics = settings.visibleMetrics
        List {
            ForEach(Array(metrics.enumerated()), id: \.element) { index, metric in
                HStack(spacing: 6) {
                    Text(metric.title)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    Button { settings.move(metric, by: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)
                    .accessibilityLabel("Move \(metric.title) up")
                    Button { settings.move(metric, by: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(index == metrics.count - 1)
                    .accessibilityLabel("Move \(metric.title) down")
                }
            }
        }
        .navigationTitle("ORDER")
    }
}
