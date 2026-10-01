import SwiftUI

struct WorkoutPickerView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(WorkoutManager.self) private var workout

    var body: some View {
        List(WorkoutActivity.allCases) { activity in
            Button {
                Task { await workout.start(activity, hapticsEnabled: settings.hapticsEnabled) }
            } label: {
                Text(activity.title)
                    .font(.system(size: 20, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Theme.primary)
            }
            .listRowBackground(Theme.background)
        }
        .navigationTitle("WORKOUT")
    }
}

/// Replaces the dashboard from START until the summary is dismissed.
struct WorkoutSessionView: View {
    @Environment(WorkoutManager.self) private var workout

    var body: some View {
        switch workout.phase {
        case .idle:
            EmptyView()
        case .starting:
            StatusView(title: "STARTING", message: nil, action: nil)
        case .running, .paused, .ending:
            LiveWorkoutView()
        case .summary(let summary):
            WorkoutSummaryView(summary: summary)
        case .failed(let message):
            StatusView(title: "WORKOUT FAILED", message: message) { workout.reset() }
        }
    }
}

/// RUN / 00:32:18 / HR 148 / DIST 3.21 MI / CAL 382.
/// Seconds tick only while the screen is fully on; Always-On drops to a once-a-minute "00:32".
struct LiveWorkoutView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(WorkoutManager.self) private var workout
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    @State private var confirmingEnd = false

    private var tickInterval: TimeInterval {
        isLuminanceReduced || workout.isPaused ? 60 : 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.label)
                    .tracking(1.2)
                    .foregroundStyle(Theme.secondary)

                TimelineView(.periodic(from: workout.startDate ?? .now, by: tickInterval)) { context in
                    Text(DisplayFormat.elapsed(workout.elapsedTime(at: context.date), showSeconds: !isLuminanceReduced))
                        .font(Theme.numeral(38, dimmed: isLuminanceReduced))
                        .foregroundStyle(isLuminanceReduced ? Theme.dimmed : Theme.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                StatLine(label: "HR", value: workout.heartRate.map { MetricFormatter.number($0, digits: 0) } ?? "--")
                if workout.activity?.tracksDistance == true {
                    StatLine(label: "DIST", value: workout.distanceMeters.map { MetricFormatter.distance($0, units: settings.units).inline } ?? "--")
                }
                StatLine(label: "CAL", value: workout.energyKcal.map { MetricFormatter.number($0, digits: 0) } ?? "--")

                if !isLuminanceReduced {
                    HStack(spacing: 8) {
                        Button(workout.isPaused ? "RESUME" : "PAUSE") {
                            if workout.isPaused { workout.resume() } else { workout.pause() }
                        }
                        Button("END") { confirmingEnd = true }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 10)
                    .disabled(workout.phase == .ending)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background.ignoresSafeArea())
        .confirmationDialog("End workout?", isPresented: $confirmingEnd) {
            Button("END WORKOUT", role: .destructive) { workout.end() }
            Button("CANCEL", role: .cancel) {}
        }
    }

    private var title: String {
        let name = workout.activity?.title ?? "WORKOUT"
        switch workout.phase {
        case .paused: return "\(name) · PAUSED"
        case .ending: return "\(name) · SAVING"
        default: return name
        }
    }
}

struct WorkoutSummaryView: View {
    let summary: WorkoutSummary

    @Environment(AppSettings.self) private var settings
    @Environment(WorkoutManager.self) private var workout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.activity.title) COMPLETE")
                    .font(Theme.label)
                    .tracking(1.2)
                    .foregroundStyle(Theme.secondary)
                Text(DisplayFormat.elapsed(summary.duration, showSeconds: true))
                    .font(Theme.numeral(34))
                    .foregroundStyle(Theme.primary)
                if let distance = summary.distanceMeters {
                    StatLine(label: "DIST", value: MetricFormatter.distance(distance, units: settings.units).inline)
                }
                if let energy = summary.energyKcal {
                    StatLine(label: "CAL", value: MetricFormatter.number(energy, digits: 0))
                }
                if let heartRate = summary.averageHeartRate {
                    StatLine(label: "AVG HR", value: MetricFormatter.number(heartRate, digits: 0))
                }
                Text(summary.saved ? "SAVED TO HEALTH" : "NOT SAVED")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.top, 6)
                Button("DONE") { workout.reset() }
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

struct StatLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(Theme.label)
                .foregroundStyle(Theme.tertiary)
                .frame(minWidth: 34, alignment: .leading)
            Text(value)
                .font(.system(size: 20, weight: .regular).monospacedDigit())
                .foregroundStyle(Theme.primary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusView: View {
    let title: String
    let message: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.primary)
            if let message {
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            if let action {
                Button("DONE", action: action)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
    }
}
