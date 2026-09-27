import AppKit
import SwiftUI
import Combine

/// Main application delegate for BatterySOT.
/// Manages the menu bar status item, popover, and coordinates all services.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - UI Components
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    // MARK: - Services
    private let batteryMonitor = BatteryMonitorService()
    private let displayMonitor = DisplayMonitorService()
    private let sessionTracker = SessionTracker()
    private let powerMetrics = PowerMetricsService()

    // MARK: - Timer
    private var displayTimer: AnyCancellable?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup UI
        setupStatusItem()
        setupPopover()

        // Start monitoring services
        startBatteryMonitoring()
        startDisplayMonitoring()

        // Start UI update timer (every 1 second for live SOT counter)
        displayTimer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateStatusBar()
            }

        // Record app launch
        DatabaseManager.shared.recordEvent(SystemEvent(
            eventType: .appLaunched,
            batteryPercentage: batteryMonitor.currentPercentage >= 0 ? batteryMonitor.currentPercentage : nil
        ))
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionTracker.handleAppTermination()
        displayTimer?.cancel()
        powerMetrics.stopTimer()
        batteryMonitor.stopMonitoring()
        displayMonitor.stopMonitoring()
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }

        // Use monospaced digits to prevent width jitter when numbers change
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.title = "🔋 --% · --:--"
        button.target = self
        button.action = #selector(statusBarClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        let dashboardView = DashboardView(
            sessionTracker: sessionTracker,
            batteryMonitor: batteryMonitor,
            powerMetrics: powerMetrics
        )

        popover = NSPopover()
        popover.contentSize = NSSize(width: 310, height: 620)
        popover.behavior = .transient  // Closes when clicking outside
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: dashboardView)
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        // Current status
        let statusItem = NSMenuItem(title: "Battery: \(batteryMonitor.currentPercentage)%", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        if sessionTracker.isInDischargeCycle {
            let sotItem = NSMenuItem(
                title: "SOT: \(Formatter.compactDuration(sessionTracker.currentScreenOnTime))",
                action: nil, keyEquivalent: ""
            )
            sotItem.isEnabled = false
            menu.addItem(sotItem)
        }

        // Live Power metrics
        let metrics = powerMetrics.currentMetrics
        if metrics.isPluggedIn {
            if let adapter = metrics.adapterWatts {
                let adapterItem = NSMenuItem(title: "Charger: \(adapter)W Adapter", action: nil, keyEquivalent: "")
                adapterItem.isEnabled = false
                menu.addItem(adapterItem)
            }
            if let sysPower = metrics.systemPowerWatts {
                let drawItem = NSMenuItem(title: "Pulling: \(Formatter.watts(sysPower))", action: nil, keyEquivalent: "")
                drawItem.isEnabled = false
                menu.addItem(drawItem)
            }
            if let battPower = metrics.batteryPowerWatts, battPower > 0 {
                let chargeItem = NSMenuItem(title: "Charging: \(Formatter.signedWatts(battPower))", action: nil, keyEquivalent: "")
                chargeItem.isEnabled = false
                menu.addItem(chargeItem)
            }
        } else {
            let draw = metrics.systemPowerWatts ?? metrics.batteryPowerWatts.map({ abs($0) })
            if let d = draw {
                let drawItem = NSMenuItem(title: "Power Draw: \(Formatter.watts(d))", action: nil, keyEquivalent: "")
                drawItem.isEnabled = false
                menu.addItem(drawItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Reset session
        let resetItem = NSMenuItem(title: "Reset Session", action: #selector(resetSession), keyEquivalent: "r")
        resetItem.target = self
        menu.addItem(resetItem)

        // Reset limit submenu
        let limitMenu = NSMenu()
        for limit in [80, 85, 90, 95, 100] {
            let item = NSMenuItem(title: "\(limit)%", action: #selector(setResetLimitFromMenu(_:)), keyEquivalent: "")
            item.tag = limit
            item.state = (sessionTracker.resetPercentageThreshold == limit) ? .on : .off
            item.target = self
            limitMenu.addItem(item)
        }
        let limitItem = NSMenuItem(title: "Auto-Reset Limit (\(sessionTracker.resetPercentageThreshold)%)", action: nil, keyEquivalent: "")
        limitItem.submenu = limitMenu
        menu.addItem(limitItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit BatterySOT", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        self.statusItem.menu = menu
        self.statusItem.button?.performClick(nil)
        self.statusItem.menu = nil  // Remove menu so left-click shows popover again
    }

    @objc private func resetSession() {
        sessionTracker.resetCurrentSession()
    }

    @objc private func setResetLimitFromMenu(_ sender: NSMenuItem) {
        sessionTracker.resetPercentageThreshold = sender.tag
    }

    /// Update the menu bar text with current battery % and SOT
    private func updateStatusBar() {
        let pct = batteryMonitor.currentPercentage

        if sessionTracker.isInDischargeCycle {
            let sot = sessionTracker.currentScreenOnTime
            let sotStr = Formatter.compactDuration(sot)

            if sessionTracker.isInChargingInterruption {
                statusItem.button?.title = "⚡ \(pct)% · \(sotStr) SOT"
            } else {
                statusItem.button?.title = "🔋 \(pct)% · \(sotStr) SOT"
            }
        } else if batteryMonitor.isCharging {
            statusItem.button?.title = "⚡ \(pct)%"
        } else if pct >= 0 {
            statusItem.button?.title = "🔋 \(pct)%"
        } else {
            statusItem.button?.title = "🔋 --%"
        }
    }

    // MARK: - Service Coordination

    private func startBatteryMonitoring() {
        batteryMonitor.startMonitoring { [weak self] snapshot in
            self?.sessionTracker.handleBatteryStateChange(snapshot)
        }
    }

    private func startDisplayMonitoring() {
        displayMonitor.startMonitoring { [weak self] isOn, timestamp in
            self?.sessionTracker.handleDisplayStateChange(isOn: isOn, timestamp: timestamp)
        }
    }
}
