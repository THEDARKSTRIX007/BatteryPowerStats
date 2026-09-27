import SwiftUI

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var dailySummaries: [DailySummary] = []

    func load() {
        dailySummaries = DatabaseManager.shared.getDailySummaries(days: 30)
    }
}

struct HistoryView: View {
    @StateObject private var vm = HistoryViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            if vm.dailySummaries.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "chart.bar")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No history yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Battery usage data will appear here\nafter your first discharge session.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(vm.dailySummaries) { summary in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Formatter.relativeDay(summary.date))
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        HStack {
                            Label(Formatter.duration(summary.totalScreenOnTime), systemImage: "sun.max")
                                .font(.caption)
                            Spacer()
                            Label("\(summary.totalBatteryUsed)% used", systemImage: "battery.25")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)

                        HStack {
                            if summary.totalSleepTime > 0 {
                                Label(Formatter.duration(summary.totalSleepTime), systemImage: "moon")
                                    .font(.caption2)
                            }
                            if summary.totalChargingDuration > 0 {
                                Label(Formatter.duration(summary.totalChargingDuration), systemImage: "bolt")
                                    .font(.caption2)
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear {
            vm.load()
        }
    }
}
