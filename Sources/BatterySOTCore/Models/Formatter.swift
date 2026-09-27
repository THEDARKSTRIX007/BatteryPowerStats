import Foundation

/// Utility functions for formatting durations and values
enum Formatter {
    /// Format a TimeInterval into a human-readable duration string
    /// e.g., 15720 seconds → "4h 22m"
    static func duration(_ interval: TimeInterval) -> String {
        guard interval >= 0 else { return "0m" }
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(String(format: "%02d", minutes))m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Format a TimeInterval into a compact string for the menu bar
    /// e.g., 15720 seconds → "4h 22m"
    static func compactDuration(_ interval: TimeInterval) -> String {
        guard interval >= 0 else { return "0m" }
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(String(format: "%02d", minutes))m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Format a TimeInterval into HH:MM:SS for the live counter
    static func liveCounter(_ interval: TimeInterval) -> String {
        guard interval >= 0 else { return "0:00:00" }
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }

    /// Format a drain rate (percent per hour)
    static func drainRate(_ rate: Double?) -> String {
        guard let rate = rate else { return "—" }
        return String(format: "%.1f%%/hr", rate)
    }

    /// Format a Date into time-only string
    static func timeOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Format a Date into a relative day string
    static func relativeDay(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }

    /// Format wattage (e.g. "12.4 W")
    static func watts(_ value: Double?) -> String {
        guard let value = value else { return "—" }
        return String(format: "%.1f W", value)
    }

    /// Format signed wattage with + or - prefix (e.g. "+24.8 W" or "-8.2 W")
    static func signedWatts(_ value: Double?) -> String {
        guard let value = value else { return "—" }
        if value > 0 {
            return String(format: "+%.1f W", value)
        } else {
            return String(format: "%.1f W", value)
        }
    }
}
