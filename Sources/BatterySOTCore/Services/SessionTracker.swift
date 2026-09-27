import Foundation

/// The central session tracking engine that coordinates battery monitoring,
/// display state tracking, and session management.
///
/// ## Terminology
///
/// - **Screen-On Time (SOT)**: The accumulated time during which the built-in
///   MacBook display was physically powered on. This is NOT the same as
///   macOS Screen Time (which tracks app/website usage) or battery discharge
///   duration (which includes sleep and screen-off time).
///
/// - **Discharge Segment**: A continuous period of battery-powered usage,
///   from the moment AC power is disconnected until AC power is reconnected.
///
/// - **Discharge Cycle**: One or more discharge segments separated by brief
///   charging interruptions. For example: unplug at 80% → charge briefly at
///   40% → unplug again → reach 20%. This is one cycle with two segments
///   and one charging interruption.
///   NOTE: This is NOT the same as Apple's "battery cycle count" which
///   measures cumulative discharge equal to 100% of capacity.
///
/// - **Charging Interruption**: A period within a discharge cycle where AC
///   power was temporarily connected. The cycle continues when AC is
///   disconnected again within a reasonable timeframe.
///
/// ## How SOT is Calculated
///
/// 1. When the display turns ON: record the timestamp as `displayOnSince`
/// 2. When the display turns OFF: add (now - displayOnSince) to the
///    current segment's screenOnTime
/// 3. The total SOT for a cycle is the sum of screenOnTime across all
///    its segments
/// 4. Sleep time and screen-off time are tracked separately
///
/// ## Charging Interruption Logic
///
/// When AC power is connected during a discharge cycle:
/// - If the charge duration is < 2 hours AND battery reaches < 100%:
///   it's treated as a "charging interruption" within the same cycle
/// - If the charge duration is >= 2 hours OR battery reaches 100%:
///   the current cycle ends and a new one begins when AC is disconnected
@MainActor
final class SessionTracker: ObservableObject {
    // MARK: - Published State

    @Published var currentCycleId: Int64 = 0
    @Published var currentSegmentId: Int64 = 0
    @Published var cycleStartTime: Date?
    @Published var cycleInitialPercentage: Int = 0
    @Published var currentPercentage: Int = 0
    @Published var lowestPercentage: Int = 100

    @Published var screenOnTimeCumulative: TimeInterval = 0  // SOT accumulated in completed intervals
    @Published var screenOffTimeCumulative: TimeInterval = 0
    @Published var sleepTimeCumulative: TimeInterval = 0

    @Published var isInDischargeCycle: Bool = false
    @Published var isInChargingInterruption: Bool = false
    @Published var isDisplayOn: Bool = true
    @Published var isSleeping: Bool = false

    @Published var chargingInterruptionCount: Int = 0
    @Published var totalChargingDuration: TimeInterval = 0

    /// Percentage threshold at which a charging session completes and resets the cycle (50...100)
    @Published var resetPercentageThreshold: Int = 100 {
        didSet {
            guard isRestored else { return }
            UserDefaults.standard.set(resetPercentageThreshold, forKey: "resetPercentageThreshold")
            if isInChargingInterruption && currentPercentage >= resetPercentageThreshold {
                endDischargeCycle(at: Date(), percentage: currentPercentage)
            }
            persistState()
        }
    }

    private var isRestored = false

    // MARK: - Timing State

    private var displayOnSince: Date?       // When the display last turned on
    private var displayOffSince: Date?      // When the display last turned off
    private var sleepSince: Date?           // When the system last went to sleep
    private var chargingStartTime: Date?    // When charging interruption started

    // Previous segment accumulated values (for cycles with interruptions)
    private var previousSegmentsSOT: TimeInterval = 0
    private var previousSegmentsScreenOff: TimeInterval = 0
    private var previousSegmentsSleep: TimeInterval = 0

    private let db: DatabaseManager
    private let maxChargingInterruptionDuration: TimeInterval = 2 * 3600 // 2 hours

    // MARK: - Computed Properties

    /// Current screen-on time including the live (ongoing) display-on interval
    var currentScreenOnTime: TimeInterval {
        var total = screenOnTimeCumulative + previousSegmentsSOT
        if let onSince = displayOnSince, isDisplayOn, !isSleeping {
            total += Date().timeIntervalSince(onSince)
        }
        return total
    }

    /// Current screen-off time including the live interval
    var currentScreenOffTime: TimeInterval {
        var total = screenOffTimeCumulative + previousSegmentsScreenOff
        if let offSince = displayOffSince, !isDisplayOn, !isSleeping {
            total += Date().timeIntervalSince(offSince)
        }
        return total
    }

    /// Current sleep time including the live interval
    var currentSleepTime: TimeInterval {
        var total = sleepTimeCumulative + previousSegmentsSleep
        if let sleepStart = sleepSince, isSleeping {
            total += Date().timeIntervalSince(sleepStart)
        }
        return total
    }

    /// Battery consumed in current cycle
    var batteryConsumed: Int {
        guard isInDischargeCycle else { return 0 }
        return max(0, cycleInitialPercentage - lowestPercentage)
    }

    /// Average drain per hour of SOT
    var averageDrainPerSOTHour: Double? {
        let sot = currentScreenOnTime
        let consumed = batteryConsumed
        guard sot > 300, consumed >= 2 else { return nil }
        return Double(consumed) / (sot / 3600.0)
    }

    /// Estimated full-charge SOT (scaled to configured reset threshold)
    var estimatedFullChargeSOT: TimeInterval? {
        guard let drain = averageDrainPerSOTHour, drain > 0,
              currentScreenOnTime > 600, batteryConsumed >= 5 else {
            return nil
        }
        return (Double(resetPercentageThreshold) / drain) * 3600.0
    }

    /// Human-readable estimation status
    var estimationStatus: String {
        if !isInDischargeCycle {
            return "Not on battery"
        }
        if currentScreenOnTime < 600 {
            return "Estimate requires more usage time"
        }
        if batteryConsumed < 5 {
            return "Estimate requires more battery usage"
        }
        return ""
    }

    // MARK: - Init

    init(database: DatabaseManager = .shared) {
        self.db = database
        let savedThreshold = UserDefaults.standard.integer(forKey: "resetPercentageThreshold")
        if savedThreshold >= 50 && savedThreshold <= 100 {
            self.resetPercentageThreshold = savedThreshold
        }
        restoreState()
        self.isRestored = true
    }

    // MARK: - Event Handlers

    /// Called when battery state changes
    func handleBatteryStateChange(_ snapshot: BatterySnapshot) {
        let now = snapshot.timestamp
        currentPercentage = snapshot.percentage

        if snapshot.powerSource == .batteryPower && !snapshot.isCharging {
            // On battery power
            if !isInDischargeCycle {
                // Starting a new discharge cycle
                startNewCycle(at: now, percentage: snapshot.percentage)
            } else if isInChargingInterruption {
                // Ending a charging interruption — AC disconnected, resuming discharge
                endChargingInterruption(at: now, percentage: snapshot.percentage)
            }

            // Update lowest percentage
            if snapshot.percentage < lowestPercentage {
                lowestPercentage = snapshot.percentage
            }

            // Update cycle state in database
            if currentCycleId > 0 {
                db.updateDischargeCycle(
                    id: currentCycleId,
                    currentPercentage: snapshot.percentage,
                    lowestPercentage: lowestPercentage
                )
            }

            // Record percentage change event
            db.recordEvent(SystemEvent(
                timestamp: now,
                eventType: .batteryPercentageChanged,
                batteryPercentage: snapshot.percentage
            ))

        } else if snapshot.isPluggedIn || snapshot.isCharging {
            // AC power connected
            if isInDischargeCycle && !isInChargingInterruption {
                // Start a charging interruption within the current cycle
                startChargingInterruption(at: now, percentage: snapshot.percentage)
            }

            // If charging for too long or reaches reset threshold, end the cycle
            if isInChargingInterruption, snapshot.percentage >= resetPercentageThreshold {
                endDischargeCycle(at: now, percentage: snapshot.percentage)
            }
        }

        persistState()
    }

    /// Called when display state changes
    func handleDisplayStateChange(isOn: Bool, timestamp: Date) {
        if isOn {
            handleDisplayOn(at: timestamp)
        } else {
            handleDisplayOff(at: timestamp)
        }
        persistState()
    }

    /// Called when the system goes to sleep
    func handleSystemSleep(at timestamp: Date = Date()) {
        guard !isSleeping else { return }

        // If display was on, accumulate the SOT up to sleep
        if isDisplayOn, let onSince = displayOnSince {
            screenOnTimeCumulative += timestamp.timeIntervalSince(onSince)
            displayOnSince = nil
        } else if !isDisplayOn, let offSince = displayOffSince {
            screenOffTimeCumulative += timestamp.timeIntervalSince(offSince)
            displayOffSince = nil
        }

        isDisplayOn = false
        isSleeping = true
        sleepSince = timestamp

        db.recordEvent(SystemEvent(
            timestamp: timestamp,
            eventType: .systemSleep,
            batteryPercentage: currentPercentage
        ))

        saveSegmentState()
        persistState()
    }

    /// Called when the system wakes
    func handleSystemWake(at timestamp: Date = Date()) {
        guard isSleeping else { return }

        // Accumulate sleep time
        if let sleepStart = sleepSince {
            sleepTimeCumulative += timestamp.timeIntervalSince(sleepStart)
            sleepSince = nil
        }

        isSleeping = false
        isDisplayOn = true
        displayOnSince = timestamp

        db.recordEvent(SystemEvent(
            timestamp: timestamp,
            eventType: .systemWake,
            batteryPercentage: currentPercentage
        ))

        // Check if charging interruption has been too long
        if isInChargingInterruption, let chargeStart = chargingStartTime {
            let chargeDuration = timestamp.timeIntervalSince(chargeStart)
            if chargeDuration > maxChargingInterruptionDuration {
                endDischargeCycle(at: timestamp, percentage: currentPercentage)
            }
        }

        persistState()
    }

    /// Called when the app is about to terminate
    func handleAppTermination() {
        let now = Date()

        // Finalize current timing
        if isDisplayOn, let onSince = displayOnSince {
            screenOnTimeCumulative += now.timeIntervalSince(onSince)
        }

        db.recordEvent(SystemEvent(
            timestamp: now,
            eventType: .appTerminating,
            batteryPercentage: currentPercentage
        ))

        saveSegmentState()
        persistState()
    }

    /// Reset the current session (keeps history)
    func resetCurrentSession() {
        let now = Date()
        if isInDischargeCycle {
            endDischargeCycle(at: now, percentage: currentPercentage)
        }
        db.resetCurrentSession()
        clearInMemoryState()
    }

    /// Clear all historical data
    func clearAllHistory() {
        db.clearAllHistory()
        clearInMemoryState()
    }

    // MARK: - Private Methods

    private func handleDisplayOn(at timestamp: Date) {
        guard !isDisplayOn else { return }

        // Accumulate screen-off time
        if let offSince = displayOffSince {
            screenOffTimeCumulative += timestamp.timeIntervalSince(offSince)
            displayOffSince = nil
        }

        isDisplayOn = true
        displayOnSince = timestamp

        db.recordEvent(SystemEvent(
            timestamp: timestamp,
            eventType: .displayOn,
            batteryPercentage: currentPercentage
        ))
    }

    private func handleDisplayOff(at timestamp: Date) {
        guard isDisplayOn else { return }

        // Accumulate screen-on time
        if let onSince = displayOnSince {
            screenOnTimeCumulative += timestamp.timeIntervalSince(onSince)
            displayOnSince = nil
        }

        isDisplayOn = false
        displayOffSince = timestamp

        db.recordEvent(SystemEvent(
            timestamp: timestamp,
            eventType: .displayOff,
            batteryPercentage: currentPercentage
        ))

        saveSegmentState()
    }

    private func startNewCycle(at timestamp: Date, percentage: Int) {
        // End any existing cycle
        if currentCycleId > 0 {
            endDischargeCycle(at: timestamp, percentage: percentage)
        }

        cycleStartTime = timestamp
        cycleInitialPercentage = percentage
        currentPercentage = percentage
        lowestPercentage = percentage
        screenOnTimeCumulative = 0
        screenOffTimeCumulative = 0
        sleepTimeCumulative = 0
        previousSegmentsSOT = 0
        previousSegmentsScreenOff = 0
        previousSegmentsSleep = 0
        chargingInterruptionCount = 0
        totalChargingDuration = 0
        isInDischargeCycle = true
        isInChargingInterruption = false

        // Start display tracking
        if isDisplayOn {
            displayOnSince = timestamp
        } else {
            displayOffSince = timestamp
        }

        // Create database records
        currentCycleId = db.createDischargeCycle(startTime: timestamp, initialPercentage: percentage)
        currentSegmentId = db.createDischargeSegment(
            cycleId: currentCycleId,
            startTime: timestamp,
            startPercentage: percentage
        )

        db.recordEvent(SystemEvent(
            timestamp: timestamp,
            eventType: .sessionStart,
            batteryPercentage: percentage,
            metadata: "cycle_\(currentCycleId)"
        ))

        db.recordEvent(SystemEvent(
            timestamp: timestamp,
            eventType: .acDisconnected,
            batteryPercentage: percentage
        ))
    }

    private func endDischargeCycle(at timestamp: Date, percentage: Int) {
        guard isInDischargeCycle else { return }

        // End active charging interruption if any
        if isInChargingInterruption {
            if let interruption = db.getActiveChargingInterruption(cycleId: currentCycleId) {
                db.endChargingInterruption(id: interruption.id, endTime: timestamp, endPercentage: percentage)
            }
        }

        // Finalize active segment
        saveSegmentState()
        if currentSegmentId > 0 {
            db.endDischargeSegment(id: currentSegmentId, endTime: timestamp, endPercentage: percentage)
        }

        // End the cycle
        db.endDischargeCycle(id: currentCycleId, endTime: timestamp)

        db.recordEvent(SystemEvent(
            timestamp: timestamp,
            eventType: .sessionEnd,
            batteryPercentage: percentage,
            metadata: "cycle_\(currentCycleId)"
        ))

        clearInMemoryState()
    }

    private func startChargingInterruption(at timestamp: Date, percentage: Int) {
        guard isInDischargeCycle, !isInChargingInterruption else { return }

        // Save current segment state and end it
        saveSegmentState()

        // Accumulate current segment times into previous totals
        previousSegmentsSOT += screenOnTimeCumulative
        if let onSince = displayOnSince {
            previousSegmentsSOT += timestamp.timeIntervalSince(onSince)
            displayOnSince = nil
        }
        previousSegmentsScreenOff += screenOffTimeCumulative
        if let offSince = displayOffSince {
            previousSegmentsScreenOff += timestamp.timeIntervalSince(offSince)
            displayOffSince = nil
        }
        previousSegmentsSleep += sleepTimeCumulative

        // End the current segment
        if currentSegmentId > 0 {
            db.endDischargeSegment(id: currentSegmentId, endTime: timestamp, endPercentage: percentage)
        }

        isInChargingInterruption = true
        chargingInterruptionCount += 1
        chargingStartTime = timestamp
        screenOnTimeCumulative = 0
        screenOffTimeCumulative = 0
        sleepTimeCumulative = 0

        let interruptionId = db.createChargingInterruption(
            cycleId: currentCycleId,
            startTime: timestamp,
            startPercentage: percentage
        )

        db.recordEvent(SystemEvent(
            timestamp: timestamp,
            eventType: .chargingInterruptionStart,
            batteryPercentage: percentage,
            metadata: "interruption_\(interruptionId)"
        ))

        db.recordEvent(SystemEvent(
            timestamp: timestamp,
            eventType: .acConnected,
            batteryPercentage: percentage
        ))
    }

    private func endChargingInterruption(at timestamp: Date, percentage: Int) {
        guard isInDischargeCycle, isInChargingInterruption else { return }

        // Calculate charging duration
        if let chargeStart = chargingStartTime {
            let duration = timestamp.timeIntervalSince(chargeStart)
            totalChargingDuration += duration

            // If charged too long, end the cycle instead
            if duration > maxChargingInterruptionDuration {
                endDischargeCycle(at: timestamp, percentage: percentage)
                // Start a new cycle
                startNewCycle(at: timestamp, percentage: percentage)
                return
            }
        }

        // End the charging interruption in DB
        if let interruption = db.getActiveChargingInterruption(cycleId: currentCycleId) {
            db.endChargingInterruption(id: interruption.id, endTime: timestamp, endPercentage: percentage)
        }

        isInChargingInterruption = false
        chargingStartTime = nil

        // Start a new discharge segment
        currentSegmentId = db.createDischargeSegment(
            cycleId: currentCycleId,
            startTime: timestamp,
            startPercentage: percentage
        )

        // Reset segment-level counters
        screenOnTimeCumulative = 0
        screenOffTimeCumulative = 0
        sleepTimeCumulative = 0

        // Re-start display tracking
        if isDisplayOn {
            displayOnSince = timestamp
        } else {
            displayOffSince = timestamp
        }

        db.recordEvent(SystemEvent(
            timestamp: timestamp,
            eventType: .chargingInterruptionEnd,
            batteryPercentage: percentage
        ))

        db.recordEvent(SystemEvent(
            timestamp: timestamp,
            eventType: .acDisconnected,
            batteryPercentage: percentage
        ))
    }

    private func saveSegmentState() {
        guard currentSegmentId > 0 else { return }
        db.updateDischargeSegment(
            id: currentSegmentId,
            endPercentage: currentPercentage,
            lowestPercentage: lowestPercentage,
            screenOnTime: screenOnTimeCumulative,
            screenOffTime: screenOffTimeCumulative,
            sleepTime: sleepTimeCumulative
        )
    }

    private func clearInMemoryState() {
        currentCycleId = 0
        currentSegmentId = 0
        cycleStartTime = nil
        cycleInitialPercentage = 0
        lowestPercentage = 100
        screenOnTimeCumulative = 0
        screenOffTimeCumulative = 0
        sleepTimeCumulative = 0
        previousSegmentsSOT = 0
        previousSegmentsScreenOff = 0
        previousSegmentsSleep = 0
        isInDischargeCycle = false
        isInChargingInterruption = false
        chargingInterruptionCount = 0
        totalChargingDuration = 0
        displayOnSince = nil
        displayOffSince = nil
        sleepSince = nil
        chargingStartTime = nil
    }

    // MARK: - State Persistence

    private func persistState() {
        let state: [String: Any] = [
            "cycleId": currentCycleId,
            "segmentId": currentSegmentId,
            "cycleStartTime": cycleStartTime?.timeIntervalSince1970 ?? 0,
            "cycleInitialPct": cycleInitialPercentage,
            "currentPct": currentPercentage,
            "lowestPct": lowestPercentage,
            "sotCumulative": screenOnTimeCumulative,
            "soffCumulative": screenOffTimeCumulative,
            "sleepCumulative": sleepTimeCumulative,
            "prevSOT": previousSegmentsSOT,
            "prevSOff": previousSegmentsScreenOff,
            "prevSleep": previousSegmentsSleep,
            "isInCycle": isInDischargeCycle,
            "isInCharging": isInChargingInterruption,
            "interruptionCount": chargingInterruptionCount,
            "totalChargeDuration": totalChargingDuration,
            "displayOnSince": displayOnSince?.timeIntervalSince1970 ?? 0,
            "displayOffSince": displayOffSince?.timeIntervalSince1970 ?? 0,
            "sleepSince": sleepSince?.timeIntervalSince1970 ?? 0,
            "chargeStartTime": chargingStartTime?.timeIntervalSince1970 ?? 0,
            "isDisplayOn": isDisplayOn,
            "isSleeping": isSleeping,
            "resetThreshold": resetPercentageThreshold,
            "lastSaveTime": Date().timeIntervalSince1970
        ]

        if let data = try? JSONSerialization.data(withJSONObject: state),
           let jsonString = String(data: data, encoding: .utf8) {
            db.saveAppState(key: "sessionTracker", value: jsonString)
        }
    }

    private func restoreState() {
        guard let jsonString = db.loadAppState(key: "sessionTracker"),
              let data = jsonString.data(using: .utf8),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        currentCycleId = state["cycleId"] as? Int64 ?? 0
        currentSegmentId = state["segmentId"] as? Int64 ?? 0

        let cycleStartEpoch = state["cycleStartTime"] as? TimeInterval ?? 0
        cycleStartTime = cycleStartEpoch > 0 ? Date(timeIntervalSince1970: cycleStartEpoch) : nil

        cycleInitialPercentage = state["cycleInitialPct"] as? Int ?? 0
        currentPercentage = state["currentPct"] as? Int ?? 0
        lowestPercentage = state["lowestPct"] as? Int ?? 100
        screenOnTimeCumulative = state["sotCumulative"] as? TimeInterval ?? 0
        screenOffTimeCumulative = state["soffCumulative"] as? TimeInterval ?? 0
        sleepTimeCumulative = state["sleepCumulative"] as? TimeInterval ?? 0
        previousSegmentsSOT = state["prevSOT"] as? TimeInterval ?? 0
        previousSegmentsScreenOff = state["prevSOff"] as? TimeInterval ?? 0
        previousSegmentsSleep = state["prevSleep"] as? TimeInterval ?? 0
        isInDischargeCycle = state["isInCycle"] as? Bool ?? false
        isInChargingInterruption = state["isInCharging"] as? Bool ?? false
        chargingInterruptionCount = state["interruptionCount"] as? Int ?? 0
        totalChargingDuration = state["totalChargeDuration"] as? TimeInterval ?? 0
        isDisplayOn = state["isDisplayOn"] as? Bool ?? true
        isSleeping = state["isSleeping"] as? Bool ?? false
        if let savedThresh = state["resetThreshold"] as? Int, savedThresh >= 50 && savedThresh <= 100 {
            resetPercentageThreshold = savedThresh
        }

        let lastSaveTime = state["lastSaveTime"] as? TimeInterval ?? 0

        // Reconstruct timing anchors
        // If the app was terminated while the display was on, we need to account for the gap
        if isInDischargeCycle && lastSaveTime > 0 {
            let lastSave = Date(timeIntervalSince1970: lastSaveTime)
            let now = Date()
            let gap = now.timeIntervalSince(lastSave)

            if isSleeping {
                // The time since last save was sleep time
                sleepTimeCumulative += gap
                sleepSince = nil
                isSleeping = false // We're clearly awake now
            }

            // We can't know the exact display state during the gap,
            // so we conservatively don't count it as SOT
            // Start fresh display tracking from now
            if isDisplayOn {
                displayOnSince = now
            } else {
                displayOffSince = now
            }

            let chargeEpoch = state["chargeStartTime"] as? TimeInterval ?? 0
            if chargeEpoch > 0 {
                chargingStartTime = Date(timeIntervalSince1970: chargeEpoch)
            }
        }

        // Record app launch event
        db.recordEvent(SystemEvent(
            timestamp: Date(),
            eventType: .appLaunched,
            batteryPercentage: nil,
            metadata: isInDischargeCycle ? "restored_cycle_\(currentCycleId)" : "no_active_cycle"
        ))
    }
}
