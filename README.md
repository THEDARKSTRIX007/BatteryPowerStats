# BatterySOT 🔋

A free, lightweight, fully open-source native macOS menu bar application specifically engineered for Apple Silicon MacBooks (M1/M2/M3/M4) that accurately tracks Screen-On Time (SOT) against battery discharge sessions.

Built with **Swift 6 / SwiftUI / AppKit**, with **zero third-party dependencies**, **zero telemetry**, and **zero cloud connections**. Compiled directly using standard Swift Package Manager (SPM) and Apple Command Line Tools.

---

## Menu Bar Preview

```
🔋 74% · 4h 12m SOT
```
*(When charging during an interruption: `⚡ 78% · 4h 12m SOT`)*

Clicking the menu bar item opens an interactive popover dashboard with live session statistics, daily summaries, estimation metrics, and CSV export.

---

## Primary Goal & Core Problem Solved

Standard macOS Screen Time tracks **application and website activity**, not physical display illumination. Furthermore:
- Built-in `pmset` logs lump together system sleep, display sleep, dark wakes, and clamshell states.
- Brief charging interruptions (e.g., plugging in for 15 minutes from 40% to 45%) typically destroy battery session history in naive tools.

**BatterySOT answers the precise question:**
> *"Since the beginning of this battery discharge session, how much actual Screen-On Time have I gotten from the built-in display?"*

### Example Scenario:
1. You unplug at 80%.
2. You use the MacBook for:
   - 1h screen ON
   - 30m screen OFF (audio playing / Mac awake)
   - 45m screen ON
3. You briefly plug in from 40% → 45% (15 min).
4. You unplug again and use for:
   - 1h screen ON down to 25%.

**BatterySOT output:**
- **Current Cycle SOT**: `2h 45m`
- **Battery Consumed**: `55%` (80% initial → 25% current)
- **Charging Interruption**: `40% → 45% (15m)` recorded and reported without resetting the cycle
- **Drain Rate**: Calculated accurately per hour of actual screen illumination

---

## Key Terminology

To avoid confusing distinct operating system concepts, BatterySOT strictly defines:

| Term | Definition |
| :--- | :--- |
| **Screen-On Time (SOT)** | The accumulated duration during which the **physical built-in MacBook display** was actively powered on and displaying content. |
| **Screen-Off Time** | Time during which the Mac was awake and running, but the built-in screen was powered down (display sleep, hot corner, idle display timeout). |
| **Sleep Time** | Time the system spent in true ACPI/SoC deep sleep. |
| **Discharge Segment** | A single continuous interval of battery power from unplug until charger connection. |
| **Discharge Cycle** | A complete usage cycle from an unplug event through discharge, which may include one or more **charging interruptions** (brief top-offs). |
| **Charging Interruption** | A temporary charging period (< 2 hours, without reaching 100%) during an ongoing discharge cycle. |
| **Apple Battery Cycle** | *(Not used for SOT)* Apple's hardware metric where 1 cycle = cumulative discharge equal to 100% of battery capacity. |

---

## Technical Architecture & macOS API Research

Before writing code, we researched all relevant macOS power and display subsystems on Apple Silicon (macOS 14+ / macOS 27):

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           BatterySOT App                                │
└────────────────────┬───────────────────────────────┬────────────────────┘
                     │                               │
         ┌───────────▼───────────┐       ┌───────────▼───────────┐
         │ BatteryMonitorService │       │ DisplayMonitorService │
         └───────────┬───────────┘       └───────────┬───────────┘
                     │                               │
                     │  IOPSNotification             │  NSWorkspace
                     │  (RunLoop Source)             │  screensDidSleep / Wake
                     │                               │  + CGDisplayIsAsleep()
                     │                               │  + CGDisplayIsBuiltin()
         ┌───────────▼───────────────────────────────▼───────────┐
         │                    SessionTracker                     │
         │   (Coordinates SOT, Segments, Cycles, Estimations)    │
         └───────────────────────────┬───────────────────────────┘
                                     │
         ┌───────────────────────────▼───────────────────────────┐
         │                    DatabaseManager                    │
         │        (Built-in libsqlite3 with WAL journal mode)    │
         └───────────────────────────────────────────────────────┘
```

### 1. Battery State Monitoring (`IOPowerSources`)
- **API**: `IOPSNotificationCreateRunLoopSource` + `IOPSCopyPowerSourcesInfo` + `IOPSGetPowerSourceDescription`.
- **Why**: It is the official, public, event-driven IOKit API.
- **Granularity**: Dispatches immediately upon AC connection/disconnection (< 50ms) and on every 1% battery percentage step change.
- **Apple Silicon specifics**: On Apple Silicon, `kIOPSCurrentCapacityKey` returns integer percentage (0–100) directly.
- **Why not `AppleSmartBattery` IORegistry?**: `AppleSmartBattery` requires continuous polling, uses private undocumented kernel driver keys that break between OS updates, and fails under strict security sandboxing.

### 2. Physical Display State Detection
- **Primary Events**:
  - `NSWorkspace.screensDidSleepNotification`: Dispatched when the display physically turns off (screen sleep, idle timer, hot corner) while the system may stay awake.
  - `NSWorkspace.screensDidWakeNotification`: Dispatched when the physical screen wakes.
- **Dark Wake Protection**: On Apple Silicon, background wakes (Power Nap, Find My, RTC maintenance) trigger `NSWorkspace.didWakeNotification`, but **do NOT** trigger `NSWorkspace.screensDidWakeNotification`. SOT is preserved and never falsely accumulated during dark wakes.
- **Hardware Validation**: `CGDisplayIsBuiltin(displayID)` identifies the internal Liquid Retina panel, and `CGDisplayIsAsleep(displayID)` verifies physical state.
- **Why not `IOFramebuffer` / `IODisplayWrangler`?**: Both are legacy Intel architectures non-existent on Apple Silicon (which uses the Apple Display Coprocessor / DCP).

### 3. High-Performance Local Persistence (`SQLite3`)
- Uses macOS's built-in `/usr/lib/libsqlite3.dylib` via `import SQLite3`.
- **Zero dependencies** (no GRDB, no Core Data overhead).
- **WAL Mode (`PRAGMA journal_mode = WAL;`)**: Atomic durability across reboots or crashes, non-blocking concurrent reads, and low write overhead.
- Constant $O(1)$ memory streaming CSV export.

---

## Dashboard Features

Clicking the status bar item opens the native SwiftUI dashboard:

- **CURRENT SESSION**:
  - Current Battery % & charging state
  - Session Start Time & Initial Battery %
  - **Live SOT Counter** (updates every second with monospaced digits)
  - Screen-off Duration
  - Battery Percentage Consumed
  - Average Drain Rate (`% / SOT hour`)
  - **Estimated SOT at Target %** (dynamically scales to your configured reset limit)
  - Charging interruption count and duration
- **LIVE POWER & WATT TRACKER** (updates every 5 seconds):
  - **On Battery**: Real-time power consumption in Watts (e.g. `9.4 W`) and voltage/current (`11.8 V · 0.80 A`)
  - **On Charger**: Connected charger specification (e.g. `67W USB-C Adapter`), power drawn from the charger (e.g. `34.5 W`), and live charging power into the battery (e.g. `+28.2 W`)
- **TODAY**:
  - Total SOT today
  - Total battery % consumed today
  - Sleep duration
  - Total charging time
- **AUTO-RESET LIMIT SLIDER**:
  - Live slider (50%–100%) and quick presets (`80%`, `100%`) directly in the menu bar dropdown
  - Automatically resets the cycle when charged up to your limit (e.g., macOS Sequoia 80% limit or AlDente)
- **CONTROLS & ACTIONS**:
  - **History**: View past 30 days of daily SOT and battery statistics
  - **Export CSV**: Stream full event log to disk
  - **Reset**: Safely close current session with confirmation dialog
  - **Settings**: Toggle Launch at Login (`SMAppService`) and Clear All History

---

## SOT Estimation Logic & Safety Guards

The app derives estimated full-charge SOT:
$$\text{Estimated Full-Charge SOT} = \frac{\text{Actual SOT}}{\text{Percentage Consumed}} \times 100$$

### Strict Safeguards:
To prevent misleading extrapolations:
- Requires **at least 10 minutes (600s)** of recorded Screen-On Time.
- Requires **at least 5% battery discharge**.
- Disabled while the Mac is charging.
- If thresholds are not met, the dashboard displays `"Estimate requires more battery usage"` rather than an inaccurate number.

---

## Build Environment & Requirements

- **Mac**: Apple Silicon MacBook (M1/M2/M3/M4, Air or Pro)
- **macOS**: macOS 14.0 Sonoma, macOS 15.0 Sequoia, or macOS 27+
- **Toolchain**: Apple Swift 5.9+ / Swift 6.x (Command Line Tools or full Xcode)

> **Command Line Tools Compatibility**:
> Unlike standard SwiftUI projects that rely on `@State` macros (which require `SwiftUIMacros.dylib` only found in Xcode.app), BatterySOT's architecture uses `@StateObject` with `ObservableObject` view models. This allows BatterySOT to be compiled using **only the lightweight Apple Command Line Tools** (`swift build`), without needing a 40 GB Xcode installation!

---

## Building and Installing

### 1. Build the `.app` Bundle
In the repository root:
```bash
make bundle
```
This compiles the release binary with SPM, sets up the macOS `.app` bundle directory structure, embeds `Info.plist` with `LSUIElement=true` (no Dock icon), and signs it with an ad-hoc code signature.

The compiled bundle will be at:
```
BatterySOT.app
```

### 2. Run Directly
```bash
open BatterySOT.app
```
or via make:
```bash
make run
```

### 3. Install to `/Applications`
```bash
make install
```

### 4. Enable Launch at Login
1. Click the **BatterySOT** icon in the menu bar.
2. Click **Settings**.
3. Toggle **Launch at Login** on. (Uses native macOS `SMAppService.mainApp`).

---

## Running Unit Tests

BatterySOT includes a comprehensive test suite with a **Mock Event Injector** that simulates all battery and display transitions without draining physical battery:

```bash
make test
```
*(or `swift run BatterySOTTests`)*

### Tested Scenarios:
1. **Unplug → display ON → display OFF**: Accurate interval accumulation
2. **Unplug → sleep → wake**: Sleep time separation and SOT preservation
3. **Unplug → charge → unplug**: Charging interruption tracking without cycle reset
4. **Reboot while battery powered**: State restoration from SQLite
5. **Reboot while charging**: Prevents false cycle initialization
6. **Battery reaches 100%**: Automatic cycle completion
7. **Battery falls below 20%**: Low battery tracking and drain calculation
8. **Display off while Mac remains awake**: Screen-off time vs sleep time distinction
9. **DarkWake**: Verifies background wakes do not falsely increment SOT
10. **External monitor connected**: Reconfiguration handling
11. **Multiple display ON/OFF transitions**: Fast cycling accuracy
12. **App launched mid-day on battery**: Correct baseline initialization

All 30 test assertions pass with zero failures.

---

## CSV Export Format

Exported CSV files contain raw, high-resolution time series events:
```csv
timestamp,timestamp_iso8601,battery_percent,event_type,metadata
1727434800,2026-09-27T11:00:00Z,90,session_start,"cycle_1"
1727434800,2026-09-27T11:00:00Z,90,ac_disconnected,""
1727434801,2026-09-27T11:00:01Z,90,display_on,""
1727438400,2026-09-27T12:00:00Z,80,battery_percentage_changed,""
1727442000,2026-09-27T13:00:00Z,70,charging_interruption_start,"interruption_1"
```

---

## Known Limitations

1. **Clamshell Mode with External Displays**: If the MacBook lid is closed while connected to an external display and running on battery, macOS powers off the internal display. BatterySOT detects this as built-in screen off.
2. **Brightness-Independent**: SOT tracks illumination state (on vs off), not display brightness percentage (e.g. 50% brightness vs 100% brightness).
3. **App Store Sandbox**: BatterySOT is designed for direct distribution. If sandboxed for the Mac App Store, standard file-access save panels are used for CSV export.

---

## Privacy Policy

- **No Network Requests**: Does not open network sockets or make HTTP requests.
- **No Analytics / Telemetry**: Zero tracking frameworks.
- **No Activity Monitoring**: Never accesses window titles, keystrokes, active applications, microphone, or camera.
- **100% Local**: All data stays in your local SQLite database (`~/Library/Application Support/BatterySOT/`).

---

## License

MIT License. See [LICENSE](LICENSE) for details.
