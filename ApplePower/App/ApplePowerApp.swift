import SwiftUI

@main
struct ApplePowerApp: App {
    @State private var settings = AppSettings()
    @State private var dashboard = DashboardStore()
    @State private var workout = WorkoutManager()
    @State private var battery = BatteryMonitor()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(dashboard)
                .environment(workout)
                .environment(battery)
                .preferredColorScheme(.dark)
                .tint(Theme.primary)
                // Re-runs only when the user changes which metrics are shown.
                .task(id: settings.trackedMetrics) {
                    await dashboard.track(settings.trackedMetrics)
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active {
                        battery.refresh()
                        Task { await dashboard.sceneDidBecomeActive() }
                    } else {
                        // Wrist down / Always-On / backgrounded: stop all HealthKit observers.
                        dashboard.sceneDidResignActive()
                    }
                }
        }
    }
}
