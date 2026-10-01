import SwiftUI

/// The home screen. Redraws once per minute and never shows seconds, so there is no per-second work at all.
struct ClockView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DashboardStore.self) private var dashboard
    @Environment(BatteryMonitor.self) private var battery
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 2) {
                Text(DisplayFormat.time(context.date, settings.timeFormat))
                    .font(Theme.numeral(64, dimmed: isLuminanceReduced))
                    .foregroundStyle(isLuminanceReduced ? Theme.dimmed : Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                // Always-On shows the time only.
                if !isLuminanceReduced {
                    details(at: context.date)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: context.date) {
                if settings.showBattery && !isLuminanceReduced { battery.refresh() }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func details(at date: Date) -> some View {
        if settings.showDate {
            Text(DisplayFormat.dateLine(date))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        if settings.showHeartRate, let heartRate = dashboard.reading(for: .heartRate) {
            Text(MetricFormatter.format(.heartRate, heartRate.value, units: settings.units).inline)
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
        if settings.showBattery, let level = battery.level {
            Text("\(level)%")
                .font(Theme.caption.monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .padding(.top, 4)
        }
    }
}
