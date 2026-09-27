import Foundation
import IOKit.ps

/// Monitors battery state using the public IOPowerSources API.
/// Event-driven: uses IOPSNotificationCreateRunLoopSource for immediate
/// notifications on battery percentage changes, charging state changes,
/// and AC ↔ Battery transitions.
///
/// This is the most authoritative API for battery state on macOS.
/// It is public, documented, App Sandbox safe, and works natively on Apple Silicon.
@MainActor
final class BatteryMonitorService: ObservableObject {
    @Published var currentPercentage: Int = -1
    @Published var isCharging: Bool = false
    @Published var isPluggedIn: Bool = false
    @Published var powerSource: PowerSourceState = .unknown
    @Published var chargingState: ChargingState = .unknown

    private var runLoopSource: CFRunLoopSource?
    private var onStateChange: ((BatterySnapshot) -> Void)?

    /// Start monitoring battery state changes.
    /// The callback fires immediately with current state, then on every change.
    func startMonitoring(onStateChange: @escaping (BatterySnapshot) -> Void) {
        self.onStateChange = onStateChange

        // Read and publish initial state
        if let snapshot = readCurrentState() {
            updatePublishedState(snapshot)
            onStateChange(snapshot)
        }

        // Set up event-driven run loop source
        // IOPSNotificationCreateRunLoopSource fires when:
        // - Battery percentage changes (1% granularity)
        // - Charging state changes
        // - AC power connected/disconnected
        // - Time remaining estimate updates
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let monitor = Unmanaged<BatteryMonitorService>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                if let snapshot = monitor.readCurrentState() {
                    monitor.updatePublishedState(snapshot)
                    monitor.onStateChange?(snapshot)
                }
            }
        }, context)?.takeRetainedValue() {
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    func stopMonitoring() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        onStateChange = nil
    }

    /// Read the current battery state snapshot from IOPowerSources.
    /// This queries the system's power source registry directly.
    func readCurrentState() -> BatterySnapshot? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            // Only process the internal battery
            guard desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            let currentCapacity = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCapacity = max(desc[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            let percentage = (currentCapacity * 100) / maxCapacity

            let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let isCharged = desc[kIOPSIsChargedKey] as? Bool ?? false
            let powerSourceStateStr = desc[kIOPSPowerSourceStateKey] as? String ?? ""

            let isPluggedIn = (powerSourceStateStr == kIOPSACPowerValue)

            let powerSource: PowerSourceState
            switch powerSourceStateStr {
            case kIOPSACPowerValue:
                powerSource = .acPower
            case kIOPSBatteryPowerValue:
                powerSource = .batteryPower
            default:
                powerSource = .unknown
            }

            let chargingState: ChargingState
            if isCharged {
                chargingState = .fullyCharged
            } else if isCharging {
                chargingState = .charging
            } else if isPluggedIn {
                chargingState = .notCharging
            } else {
                chargingState = .discharging
            }

            return BatterySnapshot(
                timestamp: Date(),
                percentage: percentage,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn,
                powerSource: powerSource,
                chargingState: chargingState
            )
        }

        return nil
    }

    private func updatePublishedState(_ snapshot: BatterySnapshot) {
        currentPercentage = snapshot.percentage
        isCharging = snapshot.isCharging
        isPluggedIn = snapshot.isPluggedIn
        powerSource = snapshot.powerSource
        chargingState = snapshot.chargingState
    }

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}
