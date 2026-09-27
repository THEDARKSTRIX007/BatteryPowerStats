import Foundation
@testable import BatterySOTCore

/// Mock Event Injector allowing unit tests to simulate battery, display, and power transitions
/// without physical battery drainage or hardware display events.
@MainActor
final class MockEventInjector {
    let tracker: SessionTracker
    let db: DatabaseManager
    private var simulatedTime: Date

    init(initialTime: Date = Date(), database: DatabaseManager) {
        self.simulatedTime = initialTime
        self.db = database
        self.tracker = SessionTracker(database: database)
    }

    func advanceTime(by seconds: TimeInterval) {
        simulatedTime = simulatedTime.addingTimeInterval(seconds)
    }

    func currentTime() -> Date {
        return simulatedTime
    }

    func injectBatteryEvent(
        percentage: Int,
        isCharging: Bool,
        isPluggedIn: Bool,
        powerSource: PowerSourceState,
        chargingState: ChargingState
    ) {
        let snapshot = BatterySnapshot(
            timestamp: simulatedTime,
            percentage: percentage,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            powerSource: powerSource,
            chargingState: chargingState
        )
        tracker.handleBatteryStateChange(snapshot)
    }

    func injectDisplayState(isOn: Bool) {
        tracker.handleDisplayStateChange(isOn: isOn, timestamp: simulatedTime)
    }

    func injectSleep() {
        tracker.handleSystemSleep(at: simulatedTime)
    }

    func injectWake() {
        tracker.handleSystemWake(at: simulatedTime)
    }

    func injectDarkWake() {
        // In macOS DarkWake, system wakes briefly for maintenance, but physical display stays OFF.
        // Display sleep state notifications do NOT fire during DarkWake.
        // SystemWake event occurs, but display remains off.
        tracker.handleSystemWake(at: simulatedTime)
        tracker.handleDisplayStateChange(isOn: false, timestamp: simulatedTime)
    }
}

// MARK: - Test Framework Runner

struct TestRunner {
    static var passedCount = 0
    static var failedCount = 0

    static func assertTest(_ condition: Bool, _ testName: String, _ message: String = "") {
        if condition {
            passedCount += 1
            print("  ✅ [PASS] \(testName)")
        } else {
            failedCount += 1
            print("  ❌ [FAIL] \(testName) - \(message)")
        }
    }
}

@main
enum BatterySOTTestRunner {
    @MainActor
    static func main() {
        print("==================================================")
        print("  BatterySOT Test Suite (Mock Event Injection)")
        print("  Environment: Apple Silicon macOS (Zero XCTest)")
        print("==================================================\n")

        func createTempDB() -> DatabaseManager {
            let tempPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("test_\(UUID().uuidString).sqlite").path
            return DatabaseManager(databasePath: tempPath)
        }

        // ----------------------------------------------------
        // TEST 1: Unplug → display ON → display OFF
        // ----------------------------------------------------
        print("Running Test 1: Unplug → display ON → display OFF...")
        do {
            let db = createTempDB()
            let mock = MockEventInjector(database: db)

            // Unplug at 80%
            mock.injectBatteryEvent(percentage: 80, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)
            mock.injectDisplayState(isOn: true)

            // 1 hour SOT
            mock.advanceTime(by: 3600)
            mock.injectDisplayState(isOn: false)

            TestRunner.assertTest(mock.tracker.isInDischargeCycle, "Test 1: In discharge cycle")
            TestRunner.assertTest(abs(mock.tracker.screenOnTimeCumulative - 3600) < 1.0,
                                  "Test 1: Recorded 1 hour SOT",
                                  "Got \(mock.tracker.screenOnTimeCumulative)s, expected 3600s")
        }

        // ----------------------------------------------------
        // TEST 2: Unplug → sleep → wake
        // ----------------------------------------------------
        print("\nRunning Test 2: Unplug → sleep → wake...")
        do {
            let db = createTempDB()
            let mock = MockEventInjector(database: db)

            mock.injectBatteryEvent(percentage: 90, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)
            mock.injectDisplayState(isOn: true)
            mock.advanceTime(by: 1800) // 30m display on

            // Put system to sleep for 2 hours
            mock.injectSleep()
            TestRunner.assertTest(mock.tracker.isSleeping, "Test 2: System entered sleep")
            TestRunner.assertTest(!mock.tracker.isDisplayOn, "Test 2: Display marked off during sleep")

            mock.advanceTime(by: 7200)
            mock.injectWake()

            TestRunner.assertTest(abs(mock.tracker.sleepTimeCumulative - 7200) < 1.0,
                                  "Test 2: Recorded 2 hours sleep time",
                                  "Got \(mock.tracker.sleepTimeCumulative)s, expected 7200s")
            TestRunner.assertTest(abs(mock.tracker.screenOnTimeCumulative - 1800) < 1.0,
                                  "Test 2: Preserved 30m SOT prior to sleep",
                                  "Got \(mock.tracker.screenOnTimeCumulative)s, expected 1800s")
        }

        // ----------------------------------------------------
        // TEST 3: Unplug → charge → unplug (Charging Interruption)
        // ----------------------------------------------------
        print("\nRunning Test 3: Unplug → charge → unplug (Charging Interruption)...")
        do {
            let db = createTempDB()
            let mock = MockEventInjector(database: db)

            mock.injectBatteryEvent(percentage: 80, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)
            mock.injectDisplayState(isOn: true)
            mock.advanceTime(by: 3600) // 1 hr SOT
            mock.injectBatteryEvent(percentage: 70, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)

            // Connect charger (charge from 70% to 75% for 15 minutes)
            mock.injectBatteryEvent(percentage: 70, isCharging: true, isPluggedIn: true,
                                    powerSource: .acPower, chargingState: .charging)

            TestRunner.assertTest(mock.tracker.isInChargingInterruption, "Test 3: Identified charging interruption")
            TestRunner.assertTest(mock.tracker.isInDischargeCycle, "Test 3: Cycle preserved across brief charge")

            mock.advanceTime(by: 900) // 15 min charging
            mock.injectBatteryEvent(percentage: 75, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)

            TestRunner.assertTest(!mock.tracker.isInChargingInterruption, "Test 3: Resumed discharge after unplug")
            TestRunner.assertTest(mock.tracker.cycleInitialPercentage == 80, "Test 3: Original start percentage (80%) preserved")
            TestRunner.assertTest(mock.tracker.chargingInterruptionCount == 1, "Test 3: Recorded 1 interruption")
        }

        // ----------------------------------------------------
        // TEST 4: Reboot while battery powered
        // ----------------------------------------------------
        print("\nRunning Test 4: Reboot while battery powered...")
        do {
            let tempPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("test_reboot_battery_\(UUID().uuidString).sqlite").path
            let db1 = DatabaseManager(databasePath: tempPath)
            let mock1 = MockEventInjector(database: db1)

            mock1.injectBatteryEvent(percentage: 85, isCharging: false, isPluggedIn: false,
                                     powerSource: .batteryPower, chargingState: .discharging)
            mock1.injectDisplayState(isOn: true)
            mock1.advanceTime(by: 1800) // 30m SOT
            mock1.injectDisplayState(isOn: false)
            mock1.tracker.handleAppTermination()

            // App launches after reboot
            let db2 = DatabaseManager(databasePath: tempPath)
            let tracker2 = SessionTracker(database: db2)

            TestRunner.assertTest(tracker2.isInDischargeCycle, "Test 4: Restored active cycle after reboot")
            TestRunner.assertTest(tracker2.cycleInitialPercentage == 85, "Test 4: Start percentage intact")
            TestRunner.assertTest(abs(tracker2.screenOnTimeCumulative - 1800) < 1.0,
                                  "Test 4: Accumulated SOT restored from SQLite")
        }

        // ----------------------------------------------------
        // TEST 5: Reboot while charging
        // ----------------------------------------------------
        print("\nRunning Test 5: Reboot while charging...")
        do {
            let tempPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("test_reboot_charge_\(UUID().uuidString).sqlite").path
            let db1 = DatabaseManager(databasePath: tempPath)
            let mock1 = MockEventInjector(database: db1)

            mock1.injectBatteryEvent(percentage: 70, isCharging: true, isPluggedIn: true,
                                     powerSource: .acPower, chargingState: .charging)
            mock1.tracker.handleAppTermination()

            let db2 = DatabaseManager(databasePath: tempPath)
            let tracker2 = SessionTracker(database: db2)

            TestRunner.assertTest(!tracker2.isInDischargeCycle, "Test 5: Did not start discharge session while AC connected")
        }

        // ----------------------------------------------------
        // TEST 6: Battery reaches 100%
        // ----------------------------------------------------
        print("\nRunning Test 6: Battery reaches 100%...")
        do {
            let db = createTempDB()
            let mock = MockEventInjector(database: db)

            mock.injectBatteryEvent(percentage: 50, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)
            TestRunner.assertTest(mock.tracker.isInDischargeCycle, "Test 6: In discharge cycle at 50%")

            // Plug in
            mock.injectBatteryEvent(percentage: 50, isCharging: true, isPluggedIn: true,
                                    powerSource: .acPower, chargingState: .charging)
            // Reaches 100%
            mock.injectBatteryEvent(percentage: 100, isCharging: true, isPluggedIn: true,
                                    powerSource: .acPower, chargingState: .fullyCharged)

            TestRunner.assertTest(!mock.tracker.isInDischargeCycle, "Test 6: Cycle cleanly ended when battery reached 100%")
        }

        // ----------------------------------------------------
        // TEST 7: Battery falls below 20%
        // ----------------------------------------------------
        print("\nRunning Test 7: Battery falls below 20%...")
        do {
            let db = createTempDB()
            let mock = MockEventInjector(database: db)

            mock.injectBatteryEvent(percentage: 30, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)
            mock.injectDisplayState(isOn: true)
            mock.advanceTime(by: 3600)
            mock.injectBatteryEvent(percentage: 18, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)

            TestRunner.assertTest(mock.tracker.lowestPercentage == 18, "Test 7: Lowest percentage updated to 18%")
            TestRunner.assertTest(mock.tracker.batteryConsumed == 12, "Test 7: Battery consumed correctly computed as 12%")
        }

        // ----------------------------------------------------
        // TEST 8: Display off while Mac remains awake
        // ----------------------------------------------------
        print("\nRunning Test 8: Display off while Mac remains awake...")
        do {
            let db = createTempDB()
            let mock = MockEventInjector(database: db)

            mock.injectBatteryEvent(percentage: 80, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)
            mock.injectDisplayState(isOn: true)
            mock.advanceTime(by: 600) // 10 min ON

            // Screen turns off (e.g. idle timeout, but audio playing keeps system awake)
            mock.injectDisplayState(isOn: false)
            mock.advanceTime(by: 1800) // 30 min OFF, awake

            // Screen wakes
            mock.injectDisplayState(isOn: true)

            TestRunner.assertTest(abs(mock.tracker.screenOnTimeCumulative - 600) < 1.0,
                                  "Test 8: SOT did NOT accumulate while screen was off",
                                  "Got \(mock.tracker.screenOnTimeCumulative)s, expected 600s")
            TestRunner.assertTest(abs(mock.tracker.screenOffTimeCumulative - 1800) < 1.0,
                                  "Test 8: Screen-off time correctly tracked while awake",
                                  "Got \(mock.tracker.screenOffTimeCumulative)s, expected 1800s")
            TestRunner.assertTest(mock.tracker.sleepTimeCumulative == 0,
                                  "Test 8: Sleep time remained 0 (system was awake)")
        }

        // ----------------------------------------------------
        // TEST 9: DarkWake (Background Maintenance Wake)
        // ----------------------------------------------------
        print("\nRunning Test 9: DarkWake handling...")
        do {
            let db = createTempDB()
            let mock = MockEventInjector(database: db)

            mock.injectBatteryEvent(percentage: 95, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)
            mock.injectDisplayState(isOn: true)
            mock.advanceTime(by: 300) // 5m SOT
            mock.injectSleep()

            mock.advanceTime(by: 1800)
            // System experiences DarkWake for 2 minutes
            mock.injectDarkWake()
            mock.advanceTime(by: 120)
            // Goes back to sleep
            mock.injectSleep()

            TestRunner.assertTest(abs(mock.tracker.screenOnTimeCumulative - 300) < 1.0,
                                  "Test 9: DarkWake did NOT count towards SOT",
                                  "Got \(mock.tracker.screenOnTimeCumulative)s, expected 300s")
        }

        // ----------------------------------------------------
        // TEST 10: External monitor connected / configuration change
        // ----------------------------------------------------
        print("\nRunning Test 10: External monitor connected...")
        do {
            let db = createTempDB()
            let mock = MockEventInjector(database: db)

            mock.injectBatteryEvent(percentage: 85, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)
            mock.injectDisplayState(isOn: true)
            mock.advanceTime(by: 600)

            // Re-evaluating display state when external monitor attaches:
            mock.injectDisplayState(isOn: true)
            mock.advanceTime(by: 600)
            mock.injectDisplayState(isOn: false)

            TestRunner.assertTest(abs(mock.tracker.screenOnTimeCumulative - 1200) < 1.0,
                                  "Test 10: Total SOT tracked smoothly across monitor connection",
                                  "Got \(mock.tracker.screenOnTimeCumulative)s, expected 1200s")
        }

        // ----------------------------------------------------
        // TEST 11: Multiple display ON/OFF transitions
        // ----------------------------------------------------
        print("\nRunning Test 11: Multiple display ON/OFF transitions...")
        do {
            let db = createTempDB()
            let mock = MockEventInjector(database: db)

            mock.injectBatteryEvent(percentage: 90, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)
            mock.injectDisplayState(isOn: true)

            // 15m ON
            mock.advanceTime(by: 900)
            mock.injectDisplayState(isOn: false)

            // 5m OFF
            mock.advanceTime(by: 300)
            mock.injectDisplayState(isOn: true)

            // 20m ON
            mock.advanceTime(by: 1200)
            mock.injectDisplayState(isOn: false)

            // 10m OFF
            mock.advanceTime(by: 600)
            mock.injectDisplayState(isOn: true)

            // 10m ON
            mock.advanceTime(by: 600)
            mock.injectDisplayState(isOn: false)

            // Total SOT: 900 + 1200 + 600 = 2700s (45m)
            // Total Screen-Off: 300 + 600 = 900s (15m)
            TestRunner.assertTest(abs(mock.tracker.screenOnTimeCumulative - 2700) < 1.0,
                                  "Test 11: Accumulated SOT across 3 ON cycles",
                                  "Got \(mock.tracker.screenOnTimeCumulative)s, expected 2700s")
            TestRunner.assertTest(abs(mock.tracker.screenOffTimeCumulative - 900) < 1.0,
                                  "Test 11: Accumulated Screen-Off across 2 OFF cycles",
                                  "Got \(mock.tracker.screenOffTimeCumulative)s, expected 900s")
        }

        // ----------------------------------------------------
        // TEST 12: App launched after Mac has already been running for hours
        // ----------------------------------------------------
        print("\nRunning Test 12: App launched mid-day on battery...")
        do {
            let db = createTempDB()
            let mock = MockEventInjector(database: db)

            // App starts up when Mac is already at 62% on battery
            mock.injectBatteryEvent(percentage: 62, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)
            mock.injectDisplayState(isOn: true)

            TestRunner.assertTest(mock.tracker.isInDischargeCycle, "Test 12: Starts tracking from current level")
            TestRunner.assertTest(mock.tracker.cycleInitialPercentage == 62, "Test 12: Initial percentage set to 62%")

            mock.advanceTime(by: 1800) // 30 min SOT
            mock.injectBatteryEvent(percentage: 58, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)
            mock.injectDisplayState(isOn: false)

            TestRunner.assertTest(mock.tracker.batteryConsumed == 4, "Test 12: Consumed calculated from launch baseline (4%)")
            TestRunner.assertTest(abs(mock.tracker.screenOnTimeCumulative - 1800) < 1.0, "Test 12: SOT accumulated properly")
        }

        // ----------------------------------------------------
        // TEST 13: Custom auto-reset percentage limit (e.g. 80%)
        // ----------------------------------------------------
        print("\nRunning Test 13: Custom auto-reset limit (80% charge limit)...")
        do {
            let db = createTempDB()
            let mock = MockEventInjector(database: db)
            mock.tracker.resetPercentageThreshold = 80

            mock.injectBatteryEvent(percentage: 50, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)
            TestRunner.assertTest(mock.tracker.isInDischargeCycle, "Test 13: In discharge cycle at 50%")

            // Plug in charger at 50%
            mock.injectBatteryEvent(percentage: 50, isCharging: true, isPluggedIn: true,
                                    powerSource: .acPower, chargingState: .charging)
            TestRunner.assertTest(mock.tracker.isInDischargeCycle, "Test 13: Cycle continues in charging interruption")

            // Charges up to 79% (below 80% limit)
            mock.injectBatteryEvent(percentage: 79, isCharging: true, isPluggedIn: true,
                                    powerSource: .acPower, chargingState: .charging)
            TestRunner.assertTest(mock.tracker.isInDischargeCycle, "Test 13: Cycle still active at 79% (below 80% limit)")

            // Reaches custom limit of 80%
            mock.injectBatteryEvent(percentage: 80, isCharging: true, isPluggedIn: true,
                                    powerSource: .acPower, chargingState: .fullyCharged)
            TestRunner.assertTest(!mock.tracker.isInDischargeCycle, "Test 13: Cycle cleanly ended when battery reached custom 80% limit")

            // Unplug from charger
            mock.injectBatteryEvent(percentage: 80, isCharging: false, isPluggedIn: false,
                                    powerSource: .batteryPower, chargingState: .discharging)
            TestRunner.assertTest(mock.tracker.isInDischargeCycle, "Test 13: Fresh discharge cycle started upon unplugging")
            TestRunner.assertTest(mock.tracker.cycleInitialPercentage == 80, "Test 13: New cycle started at 80%")
        }

        // ----------------------------------------------------
        // TEST 14: Watt Tracker and PowerMetrics calculation
        // ----------------------------------------------------
        print("\nRunning Test 14: Watt Tracker and PowerMetrics calculations...")
        do {
            // Discharging on battery: 11.4V, -1.2A -> 13.7W drain
            let dischargeMetrics = PowerMetrics(
                isCharging: false,
                isPluggedIn: false,
                systemPowerWatts: 13.7,
                batteryPowerWatts: -13.7,
                voltageVolts: 11.4,
                amperageAmps: -1.2,
                adapterWatts: nil,
                adapterName: nil
            )
            TestRunner.assertTest(Formatter.watts(dischargeMetrics.systemPowerWatts) == "13.7 W", "Test 14: Formatted power drain matches")
            TestRunner.assertTest(dischargeMetrics.adapterWatts == nil, "Test 14: No adapter when on battery")

            // Charging on AC: 67W charger, +28.5W to battery, 34.2W drawn from charger
            let chargeMetrics = PowerMetrics(
                isCharging: true,
                isPluggedIn: true,
                systemPowerWatts: 34.2,
                batteryPowerWatts: 28.5,
                voltageVolts: 12.2,
                amperageAmps: 2.34,
                adapterWatts: 67,
                adapterName: "67W USB-C Power Adapter"
            )
            TestRunner.assertTest(chargeMetrics.adapterWatts == 67, "Test 14: 67W Adapter identified")
            TestRunner.assertTest(Formatter.watts(chargeMetrics.systemPowerWatts) == "34.2 W", "Test 14: Power drawn from charger matches")
            TestRunner.assertTest(Formatter.signedWatts(chargeMetrics.batteryPowerWatts) == "+28.5 W", "Test 14: Charging power to battery matches")
        }

        print("\n==================================================")
        print("  Summary: \(TestRunner.passedCount) PASSED, \(TestRunner.failedCount) FAILED")
        print("==================================================")

        if TestRunner.failedCount > 0 {
            exit(1)
        }
    }
}
