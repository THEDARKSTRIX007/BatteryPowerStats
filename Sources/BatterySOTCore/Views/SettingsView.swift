import SwiftUI
import ServiceManagement

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var launchAtLogin = false
    @Published var showClearConfirmation = false

    func checkStatus() {
        if #available(macOS 13.0, *) {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status == .notRegistered {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                print("Launch at login error: \(error)")
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var sessionTracker: SessionTracker
    @StateObject private var vm = SettingsViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            Form {
                Section("General") {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { vm.launchAtLogin },
                        set: { vm.setLaunchAtLogin($0) }
                    ))
                }

                Section("Cycle Tracking") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Auto-Reset Limit")
                            Spacer()
                            Text("\(sessionTracker.resetPercentageThreshold)%")
                                .foregroundColor(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(sessionTracker.resetPercentageThreshold) },
                                set: { sessionTracker.resetPercentageThreshold = Int($0) }
                            ),
                            in: 50...100,
                            step: 1
                        )
                        Text("Session ends and restarts when charged to this level (e.g. 80% for macOS 15 or AlDente limit).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Data") {
                    Button(role: .destructive) {
                        vm.showClearConfirmation = true
                    } label: {
                        Label("Clear All History", systemImage: "trash")
                    }
                    .confirmationDialog("Clear all history?", isPresented: $vm.showClearConfirmation) {
                        Button("Clear All History", role: .destructive) {
                            sessionTracker.clearAllHistory()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will permanently delete ALL battery and SOT history. This cannot be undone.")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("License", value: "MIT")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("How SOT is Measured")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Screen-On Time is measured using NSWorkspace display sleep/wake notifications. It tracks when the built-in MacBook display is physically powered on, independent of system sleep. Dark wakes and maintenance wakes are NOT counted.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            vm.checkStatus()
        }
    }
}
