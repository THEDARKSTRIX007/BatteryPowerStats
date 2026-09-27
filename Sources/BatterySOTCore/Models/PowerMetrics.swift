import Foundation

/// Real-time electrical and power metrics from IOKit.
public struct PowerMetrics: Sendable, Equatable {
    public var timestamp: Date = Date()
    public var isCharging: Bool = false
    public var isPluggedIn: Bool = false

    /// Instantaneous power being drawn/consumed by the Mac (Watts).
    /// - On battery: Live power pulled from the battery (consumption).
    /// - On AC power: Total live power pulled from the charger into the Mac.
    public var systemPowerWatts: Double?

    /// Instantaneous power flow to/from the battery (Watts).
    /// - Positive (+): Charging flow into the battery.
    /// - Negative (-): Discharge flow out of the battery.
    public var batteryPowerWatts: Double?

    /// Battery voltage in Volts.
    public var voltageVolts: Double?

    /// Battery current in Amperes (signed).
    public var amperageAmps: Double?

    /// Rated wattage of the connected power adapter (e.g. 67, 96, 140 W).
    public var adapterWatts: Int?

    /// Name or description of the connected power adapter (e.g. "67W USB-C Power Adapter").
    public var adapterName: String?

    public init(
        timestamp: Date = Date(),
        isCharging: Bool = false,
        isPluggedIn: Bool = false,
        systemPowerWatts: Double? = nil,
        batteryPowerWatts: Double? = nil,
        voltageVolts: Double? = nil,
        amperageAmps: Double? = nil,
        adapterWatts: Int? = nil,
        adapterName: String? = nil
    ) {
        self.timestamp = timestamp
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.systemPowerWatts = systemPowerWatts
        self.batteryPowerWatts = batteryPowerWatts
        self.voltageVolts = voltageVolts
        self.amperageAmps = amperageAmps
        self.adapterWatts = adapterWatts
        self.adapterName = adapterName
    }
}
