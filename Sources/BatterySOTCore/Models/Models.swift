import Foundation

// MARK: - Battery State

/// Represents the power source state of the Mac
public enum PowerSourceState: String, Codable, Sendable {
    case acPower = "AC Power"
    case batteryPower = "Battery Power"
    case unknown = "Unknown"
}

/// Represents the charging state of the battery
public enum ChargingState: String, Codable, Sendable {
    case charging = "Charging"
    case discharging = "Discharging"
    case fullyCharged = "Fully Charged"
    case notCharging = "Not Charging"
    case unknown = "Unknown"
}

/// A snapshot of battery information at a point in time
public struct BatterySnapshot: Sendable {
    public let timestamp: Date
    public let percentage: Int          // 0-100
    public let isCharging: Bool
    public let isPluggedIn: Bool        // AC power connected
    public let powerSource: PowerSourceState
    public let chargingState: ChargingState

    public init(
        timestamp: Date = Date(),
        percentage: Int,
        isCharging: Bool,
        isPluggedIn: Bool,
        powerSource: PowerSourceState,
        chargingState: ChargingState
    ) {
        self.timestamp = timestamp
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.powerSource = powerSource
        self.chargingState = chargingState
    }
}

// MARK: - Display State

/// Represents the physical display state
public enum DisplayState: String, Codable, Sendable {
    case on = "On"
    case off = "Off"
}

// MARK: - System Event Types

/// Types of events that can occur
public enum SystemEventType: String, Codable, Sendable {
    // Display events
    case displayOn = "display_on"
    case displayOff = "display_off"

    // Power events
    case acConnected = "ac_connected"
    case acDisconnected = "ac_disconnected"
    case batteryPercentageChanged = "battery_percentage_changed"

    // Sleep/Wake events
    case systemSleep = "system_sleep"
    case systemWake = "system_wake"
    case screensSleep = "screens_sleep"      // display-only sleep
    case screensWake = "screens_wake"        // display-only wake

    // Session events
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case chargingInterruptionStart = "charging_interruption_start"
    case chargingInterruptionEnd = "charging_interruption_end"

    // App lifecycle
    case appLaunched = "app_launched"
    case appTerminating = "app_terminating"
}

/// A recorded system event
public struct SystemEvent: Identifiable, Sendable {
    public let id: Int64
    public let timestamp: Date
    public let eventType: SystemEventType
    public let batteryPercentage: Int?
    public let metadata: String?

    public init(
        id: Int64 = 0,
        timestamp: Date = Date(),
        eventType: SystemEventType,
        batteryPercentage: Int? = nil,
        metadata: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.eventType = eventType
        self.batteryPercentage = batteryPercentage
        self.metadata = metadata
    }
}

// MARK: - Discharge Session

/// Represents a single discharge segment (unplugged → plugged in)
public struct DischargeSegment: Identifiable, Sendable {
    public let id: Int64
    public let startTime: Date
    public var endTime: Date?
    public let startPercentage: Int
    public var endPercentage: Int?
    public var lowestPercentage: Int
    public var screenOnTime: TimeInterval     // seconds
    public var screenOffTime: TimeInterval    // seconds
    public var sleepTime: TimeInterval        // seconds
    public var isActive: Bool

    public init(
        id: Int64 = 0,
        startTime: Date = Date(),
        endTime: Date? = nil,
        startPercentage: Int,
        endPercentage: Int? = nil,
        lowestPercentage: Int? = nil,
        screenOnTime: TimeInterval = 0,
        screenOffTime: TimeInterval = 0,
        sleepTime: TimeInterval = 0,
        isActive: Bool = true
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.startPercentage = startPercentage
        self.endPercentage = endPercentage
        self.lowestPercentage = lowestPercentage ?? startPercentage
        self.screenOnTime = screenOnTime
        self.screenOffTime = screenOffTime
        self.sleepTime = sleepTime
        self.isActive = isActive
    }

    /// Battery percentage consumed during this segment
    public var batteryConsumed: Int {
        let end = endPercentage ?? startPercentage
        return max(0, startPercentage - end)
    }

    /// Average drain per hour of screen-on time
    public var averageDrainPerSOTHour: Double? {
        guard screenOnTime > 300, batteryConsumed >= 2 else { return nil } // Need 5+ min and 2%+ drain
        let sotHours = screenOnTime / 3600.0
        return Double(batteryConsumed) / sotHours
    }

    /// Estimated SOT at 100% charge (extrapolated)
    public var estimatedFullChargeSOT: TimeInterval? {
        guard let drain = averageDrainPerSOTHour, drain > 0, screenOnTime > 600, batteryConsumed >= 5 else {
            return nil
        }
        return (100.0 / drain) * 3600.0
    }
}

/// A charging interruption within a discharge cycle
public struct ChargingInterruption: Identifiable, Sendable {
    public let id: Int64
    public let startTime: Date
    public var endTime: Date?
    public let startPercentage: Int
    public var endPercentage: Int?
    public var isActive: Bool

    public init(
        id: Int64 = 0,
        startTime: Date = Date(),
        endTime: Date? = nil,
        startPercentage: Int,
        endPercentage: Int? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.startPercentage = startPercentage
        self.endPercentage = endPercentage
        self.isActive = isActive
    }

    public var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }
}

/// A discharge cycle groups multiple discharge segments and charging interruptions
/// Example: 80%→40%, charge→45%, 45%→20% is one cycle with two segments and one interruption
public struct DischargeCycle: Identifiable, Sendable {
    public let id: Int64
    public let startTime: Date
    public var endTime: Date?
    public let initialPercentage: Int
    public var currentPercentage: Int
    public var lowestPercentage: Int
    public var segments: [DischargeSegment]
    public var chargingInterruptions: [ChargingInterruption]
    public var isActive: Bool

    public init(
        id: Int64 = 0,
        startTime: Date = Date(),
        endTime: Date? = nil,
        initialPercentage: Int,
        currentPercentage: Int? = nil,
        lowestPercentage: Int? = nil,
        segments: [DischargeSegment] = [],
        chargingInterruptions: [ChargingInterruption] = [],
        isActive: Bool = true
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.initialPercentage = initialPercentage
        self.currentPercentage = currentPercentage ?? initialPercentage
        self.lowestPercentage = lowestPercentage ?? initialPercentage
        self.segments = segments
        self.chargingInterruptions = chargingInterruptions
        self.isActive = isActive
    }

    /// Total screen-on time across all segments
    public var totalScreenOnTime: TimeInterval {
        segments.reduce(0) { $0 + $1.screenOnTime }
    }

    /// Total screen-off time across all segments
    public var totalScreenOffTime: TimeInterval {
        segments.reduce(0) { $0 + $1.screenOffTime }
    }

    /// Total sleep time across all segments
    public var totalSleepTime: TimeInterval {
        segments.reduce(0) { $0 + $1.sleepTime }
    }

    /// Total battery consumed across the entire cycle
    public var totalBatteryConsumed: Int {
        max(0, initialPercentage - lowestPercentage)
    }

    /// Total charging duration across all interruptions
    public var totalChargingDuration: TimeInterval {
        chargingInterruptions.compactMap { $0.duration }.reduce(0, +)
    }

    /// Average drain per hour of SOT across the cycle
    public var averageDrainPerSOTHour: Double? {
        let totalSOT = totalScreenOnTime
        let consumed = totalBatteryConsumed
        guard totalSOT > 300, consumed >= 2 else { return nil }
        return Double(consumed) / (totalSOT / 3600.0)
    }

    /// Estimated full-charge SOT
    public var estimatedFullChargeSOT: TimeInterval? {
        guard let drain = averageDrainPerSOTHour, drain > 0,
              totalScreenOnTime > 600, totalBatteryConsumed >= 5 else {
            return nil
        }
        return (100.0 / drain) * 3600.0
    }
}

// MARK: - Daily Summary

/// Summary of battery/SOT activity for a single day
public struct DailySummary: Identifiable, Sendable {
    public let id: String  // date string "YYYY-MM-DD"
    public let date: Date
    public var totalScreenOnTime: TimeInterval
    public var totalScreenOffTime: TimeInterval
    public var totalSleepTime: TimeInterval
    public var totalBatteryUsed: Int
    public var totalChargingDuration: TimeInterval
    public var dischargeCycleCount: Int

    public init(
        date: Date,
        totalScreenOnTime: TimeInterval = 0,
        totalScreenOffTime: TimeInterval = 0,
        totalSleepTime: TimeInterval = 0,
        totalBatteryUsed: Int = 0,
        totalChargingDuration: TimeInterval = 0,
        dischargeCycleCount: Int = 0
    ) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        self.id = formatter.string(from: date)
        self.date = date
        self.totalScreenOnTime = totalScreenOnTime
        self.totalScreenOffTime = totalScreenOffTime
        self.totalSleepTime = totalSleepTime
        self.totalBatteryUsed = totalBatteryUsed
        self.totalChargingDuration = totalChargingDuration
        self.dischargeCycleCount = dischargeCycleCount
    }
}
