import SwiftUI

/// One screen of the crown carousel.
enum Page: Hashable {
    case clock
    case metric(HealthMetric)
    case workout
    case battery
    case settings
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DashboardStore.self) private var dashboard
    @Environment(WorkoutManager.self) private var workout
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    @State private var path: [Page] = []

    /// Metrics without data (unsupported sensor, no permission, never recorded) are simply left out.
    private var pages: [Page] {
        let metrics = settings.visibleMetrics.filter { dashboard.reading(for: $0) != nil }
        return [.clock] + metrics.map(Page.metric) + [.workout, .battery, .settings]
    }

    var body: some View {
        Group {
            if workout.isActive {
                WorkoutSessionView()
            } else {
                NavigationStack(path: $path) {
                    CrownPager(pages: pages) { path.append($0) }
                        .navigationDestination(for: Page.self, destination: destination)
                }
                .overlay {
                    // Wrist down: whatever screen is open, show only a dim clock on black.
                    if isLuminanceReduced {
                        ClockView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.background.ignoresSafeArea())
                    }
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .onChange(of: workout.isActive) { _, isActive in
            if isActive {
                path.removeAll()
            } else {
                Task { await dashboard.refreshAfterWorkout() }
            }
        }
    }

    @ViewBuilder
    private func destination(for page: Page) -> some View {
        switch page {
        case .clock: ClockView()
        case .metric(let metric): MetricDetailView(metric: metric)
        case .workout: WorkoutPickerView()
        case .battery: BatteryInfoView()
        case .settings: SettingsView()
        }
    }
}

/// Shows exactly one page at a time and moves between them with the Digital Crown (or a vertical swipe).
/// Only the visible page exists in the view tree, unlike a paged TabView that keeps its neighbours alive.
struct CrownPager: View {
    let pages: [Page]
    let open: (Page) -> Void

    @Environment(AppSettings.self) private var settings
    @State private var crownValue: Double = 0
    @State private var selection: Page = .clock
    @FocusState private var isFocused: Bool

    var body: some View {
        page(selection)
            .id(selection)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                if selection != .clock { open(selection) }
            }
            .gesture(DragGesture(minimumDistance: 24).onEnded(swipe))
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .digitalCrownRotation(
                $crownValue,
                from: 0,
                through: Double(max(pages.count - 1, 1)),
                by: 1,
                sensitivity: .low,
                isContinuous: false,
                isHapticFeedbackEnabled: settings.hapticsEnabled
            )
            .digitalCrownAccessory(.hidden)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { isFocused = true }
            .onChange(of: crownValue) { _, value in
                select(index: Int(value.rounded()))
            }
            .onChange(of: pages) { _, newPages in
                // Keep the current page if it still exists (e.g. a card appeared after a refresh).
                if let index = newPages.firstIndex(of: selection) {
                    crownValue = Double(index)
                } else {
                    selection = .clock
                    crownValue = 0
                }
            }
    }

    @ViewBuilder
    private func page(_ page: Page) -> some View {
        switch page {
        case .clock:
            ClockView()
        case .metric(let metric):
            MetricCardView(metric: metric)
        case .workout:
            LabelCard(systemImage: "figure.run", title: "WORKOUT", caption: "TAP TO START")
        case .battery:
            BatteryCardView()
        case .settings:
            LabelCard(systemImage: "gearshape", title: "SETTINGS", caption: nil)
        }
    }

    private func select(index: Int) {
        guard !pages.isEmpty else { return }
        let target = pages[min(max(index, 0), pages.count - 1)]
        guard target != selection else { return }
        withAnimation(settings.animationMode.animation) { selection = target }
    }

    private func swipe(_ value: DragGesture.Value) {
        let dy = value.translation.height
        guard abs(dy) > abs(value.translation.width) else { return }
        let current = pages.firstIndex(of: selection) ?? 0
        let next = dy < 0 ? current + 1 : current - 1
        guard pages.indices.contains(next) else { return }
        crownValue = Double(next)
    }
}

struct LabelCard: View {
    let systemImage: String
    let title: String
    let caption: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.primary)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.primary)
            if let caption {
                Text(caption)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
