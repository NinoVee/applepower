import Observation
import WatchKit

/// Battery level is a cheap property read, so there is no timer here: the value is refreshed when the app
/// becomes active, when the clock ticks over a minute, and when the battery screen opens.
@MainActor
@Observable
final class BatteryMonitor {
    private(set) var level: Int?
    private(set) var isCharging = false

    init() {
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        refresh()
    }

    func refresh() {
        let device = WKInterfaceDevice.current()
        let raw = device.batteryLevel
        let newLevel = raw < 0 ? nil : Int((raw * 100).rounded())
        let charging = device.batteryState == .charging || device.batteryState == .full
        // Assign only on change so an identical reading doesn't redraw anything.
        if newLevel != level { level = newLevel }
        if charging != isCharging { isCharging = charging }
    }
}
