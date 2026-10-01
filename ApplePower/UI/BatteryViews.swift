import SwiftUI

struct BatteryCardView: View {
    @Environment(BatteryMonitor.self) private var battery

    var body: some View {
        VStack(spacing: 2) {
            Text("BATTERY")
                .font(Theme.label)
                .tracking(1.2)
                .foregroundStyle(Theme.secondary)
            Text(battery.level.map { "\($0)%" } ?? "--")
                .font(Theme.numeral(54))
                .foregroundStyle(Theme.primary)
            Text(battery.isCharging ? "CHARGING" : "LOW POWER UI")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiary)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { battery.refresh() }
        .accessibilityElement(children: .combine)
    }
}

/// Describes what *this app* does to save power. It does not (and cannot) control watchOS Low Power Mode.
struct BatteryInfoView: View {
    @Environment(BatteryMonitor.self) private var battery

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                FactRow(label: "BATTERY", value: (battery.level.map { "\($0)%" } ?? "--") + (battery.isCharging ? " · CHARGING" : ""))
                FactRow(label: "MODE", value: "LOW POWER UI")
                Text("Black screen, per-minute clock, cached health data, no network, no background refresh. Sensors run continuously only during a workout you start.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                Text("System Low Power Mode is in Control Center.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("BATTERY")
        .background(Theme.background.ignoresSafeArea())
        .onAppear { battery.refresh() }
    }
}
