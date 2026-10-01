# ApplePower

A minimalist, battery-first Apple Watch app: a large digital clock plus a Digital Crown carousel of
HealthKit measurements, in white text on a pure-black OLED background.

```
10:42          ── crown ──▶   HEART RATE   ── crown ──▶   STEPS     ── … ──▶  WORKOUT · BATTERY · SETTINGS
TUE SEP 30                       72                       7,842
72 BPM                           BPM                      STEPS
78%                             10:38 PM                  10:41 PM
```

The app doesn't and can't override watchOS power management. What it does is keep its own work as
small as watchOS and HealthKit allow.

## Requirements

- Xcode 16 or later (the project uses folder-synchronized groups, project format 77)
- watchOS 10.0+ deployment target
- An Apple Watch or the watchOS simulator. The simulator has little health data, so most cards stay hidden there.

## Getting started

1. Open `ApplePower.xcodeproj`.
2. Select the **ApplePower** target → *Signing & Capabilities*, choose your team, and change the bundle
   identifier (`com.example.applepower.watchkitapp`) to one you own. The HealthKit capability is already
   set in `Config/ApplePower.entitlements`.
3. Run on a paired watch or a watchOS simulator.

It's a standalone watch-only app (`WKWatchOnly`), so there's no iPhone target. Health data recorded on the
iPhone still shows up because HealthKit syncs it to the watch.

> Apple's App Store guidelines don't allow "Apple" in third-party app names. Change the display name
> (`INFOPLIST_KEY_CFBundleDisplayName`) before submitting.

## Using it

| Action | Result |
| --- | --- |
| Rotate the Digital Crown (or swipe vertically) | Move through the clock, the enabled metrics, Workout, Battery and Settings |
| Tap a metric | Details: latest value, range and average, `TODAY \| 7 DAYS \| 30 DAYS`, a simple bar strip, last updated |
| Tap **Workout** | Choose Walk, Run, Cycle or Strength. The live screen shows elapsed time, HR, distance and calories |
| Lower your wrist | Always-On shows only a dim, thin clock, whatever screen was open |

The carousel hides any metric that has no data: the sensor isn't on this watch model, read access was
denied, or the metric was never recorded. You never see an error or an empty card.

## Architecture

```
ApplePower/
├── App/ApplePowerApp.swift          Entry point; wires scene phase → refresh/observer lifecycle
├── UI/                              UI layer
│   ├── RootView.swift               NavigationStack + CrownPager (one page in the tree at a time)
│   ├── ClockView.swift              TimelineView(.everyMinute) clock
│   ├── MetricViews.swift            Metric card, detail screen, Canvas bar strip
│   ├── WorkoutViews.swift           Activity picker, live workout, summary
│   ├── BatteryViews.swift           Battery card + info screen
│   ├── SettingsViews.swift          Settings, metric selection, metric order
│   └── Theme.swift                  Colours, fonts, value/date formatting
├── Health/                          Health data layer
│   ├── HealthMetric.swift           Supported metrics: HealthKit type, unit, refresh interval
│   ├── HealthModels.swift           Reading / history models, sleep interval merging
│   └── HealthDataService.swift      Authorization, one-shot async queries, observer queries
├── Dashboard/DashboardStore.swift   Refresh policy: staleness, coalescing, what's visible
├── Cache/MetricCache.swift          Cache layer: on-device JSON snapshot of the latest values
├── Workout/WorkoutManager.swift     Workout layer: HKWorkoutSession + HKLiveWorkoutBuilder
├── Battery/BatteryMonitor.swift     Battery level, read on demand
└── Settings/AppSettings.swift       Settings layer: preferences, enabled metrics, order
Config/                              Info.plist (usage strings, workout background mode), entitlements
```

State lives in four `@Observable` objects (`AppSettings`, `DashboardStore`, `WorkoutManager`,
`BatteryMonitor`) injected through the SwiftUI environment. With Observation's per-property tracking, a
change to one value only redraws the views that read it.

## Battery-saving design

**Display**
- Pure black background and white or grey text only, with no gradients, fills, accent colours or decoration.
- Large numerals use light and thin font weights. Thinner strokes light fewer OLED pixels.
- The clock redraws once a minute (`TimelineView(.everyMinute)`) and never shows seconds.
- Always-On mode replaces whatever screen is open with a dim, thin clock and nothing else.
- The crown carousel keeps only the visible page in the view tree. A paged `TabView` would keep its neighbours alive.
- The only animation is an optional 0.15 s cross-fade between pages, and **Animations: Off** removes it.
  There are no other animations, spinners or moving elements.
- History is drawn as a single `Canvas` path of grey bars. There are no chart frameworks, axes or animations.

**HealthKit**
- Values are drawn straight from an on-device cache at launch, so drawing a screen never needs a query.
- Each metric has its own refresh interval: heart rate every 2 min, activity totals every 5–15 min, HRV and
  SpO₂ every 30 min, resting HR and sleep hourly, VO₂ max and wrist temperature every 6 h. When the app
  becomes active, only stale metrics are queried.
- While the app is in the foreground, `HKObserverQuery`s report new samples. Events are batched for 10 s and
  refreshed together. All observers stop as soon as the app goes inactive (wrist down) or into the background.
- Metrics that return no data are re-checked at most every 6 hours.
- Disabled metrics are never queried, observed or requested.
- Statistics queries are used for totals, so HealthKit de-duplicates sources instead of the app reading raw samples.
- History is queried only when a detail screen is opened, only for the selected range, and kept in memory for 10 minutes.
- The app never activates a sensor to fill in a value. It reads whatever watchOS has already recorded.

**Everything else**
- There are no timers. Battery level is a property read when the app becomes active, when the clock's minute changes, or when the battery screen opens.
- There's no networking code at all, and no analytics or ads.
- No location is used. Continuous sensors (heart rate, GPS for outdoor distance) run only inside a workout
  session the user starts, and stop when it ends.
- No background refresh tasks and no complications. The app does work only while it's on screen.
- Haptics are off by default, both for the crown detents and for workout start and stop.
- SwiftUI only assigns observed values when they change, so an unchanged reading doesn't trigger a redraw.

## Privacy

- Read permission is requested only for the metrics you enable. Turning on another metric in
  Settings asks for that one alone.
- Workout write permission is requested the first time you start a workout, not at launch.
- Health values never leave the watch. The cache is a small file in Application Support with file protection
  and excluded from backups. **Settings → Clear cache** deletes it.
- The app contains no network code.

## Settings

| Setting | Options |
| --- | --- |
| Time | 12 hour / 24 hour (defaults to the locale) |
| Units | Imperial / Metric (defaults to the locale) |
| Animations | Minimal / Off |
| Haptics | On / Off (default off) |
| Clock | Show date, heart rate and battery under the time |
| Metrics | Choose which measurements appear |
| Order | Reorder the enabled measurements |

## Supported measurements

Heart rate, resting heart rate, walking heart rate average, HRV (SDNN), blood oxygen, respiratory rate,
sleeping wrist temperature, steps, walking and running distance, cycling distance, active energy, exercise
minutes, stand hours, flights climbed, workouts, sleep (time asleep, merged across sources), and VO₂ max.
The defaults are heart rate, steps, active energy, HRV, blood oxygen, resting HR, exercise and sleep.

## Known limitations / next steps

- The project hasn't been built in Xcode yet. It was written without access to a Swift toolchain, so expect
  to fix small compile issues the first time you build.
- Workout crash recovery (`WKApplicationDelegate.handleActiveWorkoutRecovery`) isn't implemented.
- Workouts don't record GPS routes. Distance comes from the workout session. A route would need
  `HKWorkoutRouteBuilder` and location permission.
- There are no complications or widgets. Adding one would also mean scheduling background refreshes,
  which would cost battery.
- The app icon is an empty placeholder in `Assets.xcassets/AppIcon.appiconset`.
