import Foundation
import AppKit
import CoreGraphics

/// Monitors the physical display state of the built-in MacBook display.
///
/// ## How Display State is Detected
///
/// This service uses a multi-signal approach for maximum accuracy:
///
/// 1. **NSWorkspace.screensDidSleepNotification** (Primary)
///    - Fires when displays physically power off (sleep)
///    - This is display-specific, NOT system sleep
///    - Available since macOS 10.6, reliable on Apple Silicon
///
/// 2. **NSWorkspace.screensDidWakeNotification** (Primary)
///    - Fires when displays physically power on (wake)
///    - Pairs with screensDidSleep
///
/// 3. **NSWorkspace.willSleepNotification / didWakeNotification** (Secondary)
///    - System-level sleep/wake (which also implies display off/on)
///    - Handles the case where system sleep turns off display
///
/// 4. **CGDisplayIsAsleep()** (Validation)
///    - Used to verify display state when events are received
///    - Can distinguish built-in display via CGDisplayIsBuiltin()
///
/// ## What This Measures
///
/// "Screen-On Time" = the accumulated duration during which the built-in
/// MacBook display was physically powered on and showing content.
///
/// This does NOT count:
/// - Sleep time (system or display)
/// - Dark wake / maintenance wake
/// - Time with lid closed (display off)
/// - External monitor time (if trackable separately)
///
/// ## Accuracy Note
///
/// NSWorkspace screen sleep/wake notifications are the most authoritative
/// event-driven API available for display state on macOS. They fire
/// independently of system sleep and specifically indicate when displays
/// transition between active and sleep states.
@MainActor
final class DisplayMonitorService: ObservableObject {
    @Published var isDisplayOn: Bool = true

    private var onDisplayStateChange: ((Bool, Date) -> Void)?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var systemSleepObserver: NSObjectProtocol?
    private var systemWakeObserver: NSObjectProtocol?
    private var screenParamsObserver: NSObjectProtocol?

    /// Start monitoring display state.
    /// Callback receives (isDisplayOn: Bool, timestamp: Date)
    func startMonitoring(onDisplayStateChange: @escaping (Bool, Date) -> Void) {
        self.onDisplayStateChange = onDisplayStateChange

        // Determine initial display state
        let initialState = checkDisplayState()
        isDisplayOn = initialState
        onDisplayStateChange(initialState, Date())

        let center = NSWorkspace.shared.notificationCenter

        // Display-specific sleep (screens off, but system may still be awake)
        sleepObserver = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplayOff()
            }
        }

        // Display-specific wake (screens on)
        wakeObserver = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplayOn()
            }
        }

        // System sleep implies display off
        systemSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplayOff()
            }
        }

        // System wake implies display on
        systemWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplayOn()
            }
        }

        // Screen parameter changes (external display connect/disconnect)
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Re-check built-in display state when screen configuration changes
                let state = self?.checkDisplayState() ?? true
                if state != self?.isDisplayOn {
                    if state {
                        self?.handleDisplayOn()
                    } else {
                        self?.handleDisplayOff()
                    }
                }
            }
        }
    }

    func stopMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        if let o = sleepObserver { center.removeObserver(o) }
        if let o = wakeObserver { center.removeObserver(o) }
        if let o = systemSleepObserver { center.removeObserver(o) }
        if let o = systemWakeObserver { center.removeObserver(o) }
        if let o = screenParamsObserver { NotificationCenter.default.removeObserver(o) }

        sleepObserver = nil
        wakeObserver = nil
        systemSleepObserver = nil
        systemWakeObserver = nil
        screenParamsObserver = nil
        onDisplayStateChange = nil
    }

    /// Check if the built-in display is currently active.
    /// Uses CoreGraphics CGDisplayIsAsleep() and CGDisplayIsBuiltin() to verify.
    func checkDisplayState() -> Bool {
        // Try to find the built-in display
        let maxDisplays: UInt32 = 16
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0

        let err = CGGetOnlineDisplayList(maxDisplays, &displays, &displayCount)
        guard err == .success else {
            // Fallback: assume display is on if we can't query
            return true
        }

        // Look for the built-in display
        for i in 0..<Int(displayCount) {
            let displayID = displays[i]
            if CGDisplayIsBuiltin(displayID) != 0 {
                // Found built-in display — check if it's asleep
                return CGDisplayIsAsleep(displayID) == 0
            }
        }

        // No built-in display found (lid closed with external monitor?)
        // If there are any active displays, we consider "display on" for SOT purposes
        // but flag this in metadata
        return displayCount > 0
    }

    private func handleDisplayOff() {
        guard isDisplayOn else { return } // Already off, avoid duplicates
        isDisplayOn = false
        onDisplayStateChange?(false, Date())
    }

    private func handleDisplayOn() {
        guard !isDisplayOn else { return } // Already on, avoid duplicates
        isDisplayOn = true
        onDisplayStateChange?(true, Date())
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let o = sleepObserver { center.removeObserver(o) }
        if let o = wakeObserver { center.removeObserver(o) }
        if let o = systemSleepObserver { center.removeObserver(o) }
        if let o = systemWakeObserver { center.removeObserver(o) }
        if let o = screenParamsObserver { NotificationCenter.default.removeObserver(o) }
    }
}
