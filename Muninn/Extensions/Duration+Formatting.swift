import Foundation

extension TimeInterval {
    /// Formats duration as "1h 23m" or "45m" or "5m"
    var formattedDuration: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "<1m"
        }
    }

    /// Formats duration as "1:23:45" or "23:45" or "0:45"
    var formattedTimestamp: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    /// Formats remaining time as "-1:23:45" or "-23:45"
    var formattedRemaining: String {
        "-" + formattedTimestamp
    }
}
