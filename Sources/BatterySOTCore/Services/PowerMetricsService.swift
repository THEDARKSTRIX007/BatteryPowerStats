import Foundation
import Combine
import IOKit
import IOKit.ps

/// Service that monitors real-time electrical power metrics (Watts, Volts, Amperes)
/// and connected charger specifications.
///
/// Polls every 5 seconds (as per macOS power management best practices) and
/// supports immediate on-demand refresh.
@MainActor
public final class PowerMetricsService: ObservableObject {
    @Published public private(set) var currentMetrics: PowerMetrics = PowerMetrics()

    private var timerSubscription: AnyCancellable?
    private let updateInterval: TimeInterval

    public init(updateInterval: TimeInterval = 5.0) {
        self.updateInterval = updateInterval
        // Read immediately on initialization
        self.currentMetrics = readPowerMetrics()
        startTimer()
    }

    /// Start polling every 5 seconds
    public func startTimer() {
        timerSubscription?.cancel()
        timerSubscription = Timer.publish(every: updateInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    /// Stop polling timer
    public func stopTimer() {
        timerSubscription?.cancel()
        timerSubscription = nil
    }

    /// Refresh power metrics immediately
    public func refresh() {
        self.currentMetrics = readPowerMetrics()
    }

    /// Query IOKit and IOPowerSources for instantaneous electrical power data
    public func readPowerMetrics() -> PowerMetrics {
        var metrics = PowerMetrics(timestamp: Date())

        // 1. Query external power adapter details using official public API
        if let adapterDetails = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            if let watts = adapterDetails[kIOPSPowerAdapterWattsKey] as? Int, watts > 0 {
                metrics.adapterWatts = watts
            }
            if let name = (adapterDetails["Name"] as? String) ?? (adapterDetails["Description"] as? String), !name.isEmpty {
                metrics.adapterName = name
            } else if let watts = metrics.adapterWatts {
                metrics.adapterName = "\(watts)W USB-C Power Adapter"
            }
        }

        // 2. Query AppleSmartBattery IORegistry entry
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any] {

                let isCharging = dict["IsCharging"] as? Bool ?? false
                let isPluggedIn = (dict["ExternalConnected"] as? Bool ?? false) || (metrics.adapterWatts != nil)
                metrics.isCharging = isCharging
                metrics.isPluggedIn = isPluggedIn

                // Fallback adapter details if not retrieved by IOPSCopyExternalPowerAdapterDetails
                if metrics.adapterWatts == nil, let adapterDict = dict["AdapterDetails"] as? [String: Any] {
                    if let watts = adapterDict["Watts"] as? Int, watts > 0 {
                        metrics.adapterWatts = watts
                        metrics.adapterName = adapterDict["Name"] as? String ?? "\(watts)W Power Adapter"
                    }
                }

                // Check PowerTelemetryData (available on Apple Silicon Macs)
                if let telemetry = dict["PowerTelemetryData"] as? [String: Any] {
                    // SystemPowerIn is in milliwatts (mW)
                    if let sysPowerNum = telemetry["SystemPowerIn"] as? NSNumber {
                        let watts = sysPowerNum.doubleValue / 1000.0
                        if watts > 0 {
                            metrics.systemPowerWatts = (watts * 10).rounded() / 10.0
                        }
                    }
                    // BatteryPower is in milliwatts (mW)
                    if let battPowerNum = telemetry["BatteryPower"] as? NSNumber {
                        let watts = battPowerNum.doubleValue / 1000.0
                        metrics.batteryPowerWatts = (watts * 10).rounded() / 10.0
                    }
                }

                // Voltage and Amperage reading (universal across Apple Silicon & Intel)
                var voltage_mV: Double? = nil
                if let vNum = dict["Voltage"] as? NSNumber {
                    voltage_mV = vNum.doubleValue
                    metrics.voltageVolts = (vNum.doubleValue / 100.0).rounded() / 10.0 // e.g. 11.4 V
                }

                var amperage_mA: Double? = nil
                if let aNum = dict["Amperage"] as? NSNumber {
                    let rawUInt = aNum.uint64Value
                    // Handle 64-bit signed representation for negative discharge current
                    if rawUInt > UInt64(Int64.max) {
                        amperage_mA = Double(Int64(bitPattern: rawUInt))
                    } else {
                        amperage_mA = aNum.doubleValue
                    }
                    if let i = amperage_mA {
                        metrics.amperageAmps = (i / 100.0).rounded() / 10.0 // e.g. 1.2 A
                    }
                }

                // Calculate instantaneous power from Voltage * Current
                if let v = voltage_mV, let i = amperage_mA, v > 0 {
                    let calculatedWatts = (v * i) / 1_000_000.0
                    let roundedWatts = (calculatedWatts * 10).rounded() / 10.0

                    if metrics.batteryPowerWatts == nil {
                        metrics.batteryPowerWatts = roundedWatts
                    }

                    if metrics.systemPowerWatts == nil {
                        if !isPluggedIn {
                            // On battery: system consumption is the battery discharge rate
                            metrics.systemPowerWatts = abs(roundedWatts)
                        } else if isCharging && roundedWatts > 0 {
                            // On charger and charging: battery charging flow
                            metrics.systemPowerWatts = roundedWatts
                        }
                    }
                }
            }
        }

        // On battery fallback: if systemPowerWatts is still nil, derive from batteryPowerWatts
        if !metrics.isPluggedIn, let bPower = metrics.batteryPowerWatts, metrics.systemPowerWatts == nil {
            metrics.systemPowerWatts = abs(bPower)
        }

        return metrics
    }
}
