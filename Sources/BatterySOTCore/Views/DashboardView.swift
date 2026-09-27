import SwiftUI
import AppKit
import Combine

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var currentSOT: TimeInterval = 0
    @Published var currentScreenOff: TimeInterval = 0
    @Published var currentSleep: TimeInterval = 0
    @Published var todayTotalSOT: TimeInterval = 0
    @Published var todayBatteryUsed: Int = 0
    @Published var todaySleep: TimeInterval = 0
    @Published var todayCharging: TimeInterval = 0
    @Published var showHistory = false
    @Published var showSettings = false
    @Published var showResetConfirmation = false
}

struct DashboardView: View {
    @ObservedObject var sessionTracker: SessionTracker
    @ObservedObject var batteryMonitor: BatteryMonitorService
    @ObservedObject var powerMetrics: PowerMetricsService
    @StateObject private var vm = DashboardViewModel()

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Text("Battery SOT")
                        .font(.headline)
                    Spacer()
                    Text(batteryStatusIcon)
                        .font(.title3)
                }
                .padding(.bottom, 4)

                Divider()

                if sessionTracker.isInDischargeCycle {
                    currentSessionSection
                } else {
                    noSessionView
                }

                Divider()

                powerSection

                Divider()

                todaySection

                Divider()

                resetLimitSection

                Divider()

                actionButtons
            }
            .padding(16)
        }
        .frame(width: 310, height: 620)
        .onReceive(timer) { _ in
            updateLiveTimers()
        }
        .onAppear {
            updateLiveTimers()
        }
        .sheet(isPresented: $vm.showHistory) {
            HistoryView()
                .frame(width: 400, height: 500)
        }
        .sheet(isPresented: $vm.showSettings) {
            SettingsView(sessionTracker: sessionTracker)
                .frame(width: 350, height: 300)
        }
    }

    // MARK: - Current Session

    private var currentSessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CURRENT SESSION")
                .font(.caption)
                .foregroundColor(.secondary)
                .fontWeight(.semibold)

            statRow("Battery", "\(batteryMonitor.currentPercentage)%")

            if let startTime = sessionTracker.cycleStartTime {
                statRow("Started", Formatter.timeOnly(startTime))
            }

            statRow("Started at", "\(sessionTracker.cycleInitialPercentage)%")

            statRow("Current SOT", Formatter.liveCounter(vm.currentSOT))
                .fontWeight(.medium)

            statRow("Screen-off", Formatter.duration(vm.currentScreenOff))

            statRow("Battery consumed", "\(sessionTracker.batteryConsumed)%")

            statRow("Avg drain", Formatter.drainRate(sessionTracker.averageDrainPerSOTHour))

            // Estimated full-charge SOT
            if let estimate = sessionTracker.estimatedFullChargeSOT {
                statRow("Est. SOT at \(sessionTracker.resetPercentageThreshold)%", "~\(Formatter.duration(estimate))")
                    .foregroundColor(.blue)
            } else {
                let status = sessionTracker.estimationStatus
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .italic()
                }
            }

            // Charging interruptions
            if sessionTracker.chargingInterruptionCount > 0 {
                HStack {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                    Text("\(sessionTracker.chargingInterruptionCount) charging interruption(s)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 2)
            }

            if sessionTracker.isInChargingInterruption {
                Label("Currently charging (interruption)", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
    }

    private var noSessionView: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("No active discharge session")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Unplug from AC power to start tracking")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Live Watt Tracker

    private var powerSection: some View {
        let metrics = powerMetrics.currentMetrics
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("LIVE POWER TRACKER", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fontWeight(.semibold)
                Spacer()
                Text("Updates 5s")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if metrics.isPluggedIn || batteryMonitor.isPluggedIn {
                // Connected to Charger
                if let adapter = metrics.adapterWatts {
                    statRow("Connected Charger", "\(adapter)W USB-C")
                } else if let name = metrics.adapterName {
                    statRow("Connected Charger", name)
                } else {
                    statRow("Power Source", "AC Power")
                }

                if let sysPower = metrics.systemPowerWatts {
                    statRow("Power Drawn from Charger", Formatter.watts(sysPower))
                }

                if metrics.isCharging || batteryMonitor.isCharging {
                    if let battPower = metrics.batteryPowerWatts, battPower > 0 {
                        statRow("Charging Power to Battery", Formatter.signedWatts(battPower))
                            .foregroundColor(.green)
                    } else if let sysPower = metrics.systemPowerWatts {
                        statRow("Charging Power to Battery", Formatter.watts(sysPower))
                            .foregroundColor(.green)
                    }
                } else {
                    statRow("Battery State", "Bypassed (Powering Mac)")
                        .foregroundColor(.secondary)
                }

                if let v = metrics.voltageVolts, let i = metrics.amperageAmps {
                    statRow("Electrical", String(format: "%.1f V · %.2f A", v, abs(i)))
                }
            } else {
                // On Battery Power (Discharging)
                if let sysPower = metrics.systemPowerWatts {
                    statRow("Current Power Consumption", Formatter.watts(sysPower))
                        .fontWeight(.medium)
                } else if let battPower = metrics.batteryPowerWatts {
                    statRow("Current Power Consumption", Formatter.watts(abs(battPower)))
                        .fontWeight(.medium)
                } else {
                    statRow("Current Power Consumption", "Measuring...")
                }

                if let v = metrics.voltageVolts, let i = metrics.amperageAmps {
                    statRow("Electrical", String(format: "%.1f V · %.2f A", v, abs(i)))
                }
            }
        }
    }

    // MARK: - Today Section

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TODAY (ALL POWER SOURCES)")
                .font(.caption)
                .foregroundColor(.secondary)
                .fontWeight(.semibold)

            statRow("Total SOT", Formatter.duration(vm.todayTotalSOT))
            statRow("Battery used", "\(vm.todayBatteryUsed)%")
            statRow("Sleep", Formatter.duration(vm.todaySleep))

            if vm.todayCharging > 0 {
                statRow("Charging", Formatter.duration(vm.todayCharging))
            }
        }
    }

    // MARK: - Auto-Reset Limit

    private var resetLimitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Auto-Reset Limit", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(sessionTracker.resetPercentageThreshold)%")
                    .font(.caption)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
            }

            Slider(
                value: Binding(
                    get: { Double(sessionTracker.resetPercentageThreshold) },
                    set: { sessionTracker.resetPercentageThreshold = Int($0) }
                ),
                in: 50...100,
                step: 1
            )

            HStack {
                Text("Resets when charged to limit")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("80%") {
                    sessionTracker.resetPercentageThreshold = 80
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button("100%") {
                    sessionTracker.resetPercentageThreshold = 100
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: { vm.showHistory = true }) {
                    Label("History", systemImage: "clock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: exportCSV) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Button(action: { vm.showSettings = true }) {
                    Label("Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive, action: { vm.showResetConfirmation = true }) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .confirmationDialog("Reset current session?", isPresented: $vm.showResetConfirmation) {
                    Button("Reset Session", role: .destructive) {
                        sessionTracker.resetCurrentSession()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will end the current discharge session. Historical data will be preserved.")
                }
            }

            Button("Quit BatterySOT") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.top, 4)
        }
    }

    // MARK: - Helpers

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .monospacedDigit()
        }
    }

    private var batteryStatusIcon: String {
        let pct = batteryMonitor.currentPercentage
        if batteryMonitor.isCharging {
            return "⚡️ \(pct)%"
        } else if pct > 80 {
            return "🔋 \(pct)%"
        } else if pct > 20 {
            return "🔋 \(pct)%"
        } else {
            return "🪫 \(pct)%"
        }
    }

    private func updateLiveTimers() {
        vm.currentSOT = sessionTracker.currentScreenOnTime
        vm.currentScreenOff = sessionTracker.currentScreenOffTime
        vm.currentSleep = sessionTracker.currentSleepTime

        let todaySummary = DatabaseManager.shared.getTodaySummary()
        var liveTodaySOT = todaySummary.totalScreenOnTime
        if sessionTracker.isDisplayOn && !sessionTracker.isSleeping {
            liveTodaySOT = max(liveTodaySOT, vm.currentSOT)
        }
        vm.todayTotalSOT = liveTodaySOT
        vm.todayBatteryUsed = max(todaySummary.totalBatteryUsed, sessionTracker.batteryConsumed)
        vm.todaySleep = max(todaySummary.totalSleepTime, vm.currentSleep)
        vm.todayCharging = max(todaySummary.totalChargingDuration, sessionTracker.totalChargingDuration)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "batterysot_export.csv"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try DatabaseManager.shared.exportToCSV(destinationURL: url)
            } catch {
                print("Export failed: \(error)")
            }
        }
    }
}
