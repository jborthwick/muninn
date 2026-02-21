import Foundation

extension Date {
    /// Returns a human-readable relative date string with time for recent episodes
    /// e.g., "Today 2:30 PM", "Yesterday 9:00 AM", "Mon 3:15 PM", "Dec 15", "Dec 15, 2023"
    var relativeFormatted: String {
        let calendar = Calendar.current
        let now = Date()
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let timeString = timeFormatter.string(from: self)

        if calendar.isDateInToday(self) {
            return "Today \(timeString)"
        }

        if calendar.isDateInYesterday(self) {
            return "Yesterday \(timeString)"
        }

        let components = calendar.dateComponents([.day], from: self, to: now)
        if let days = components.day, days < 7 {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEE"  // Mon, Tue, etc.
            return "\(dayFormatter.string(from: self)) \(timeString)"
        }

        // Check if same year
        let thisYear = calendar.component(.year, from: now)
        let dateYear = calendar.component(.year, from: self)

        if thisYear == dateYear {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: self)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: self)
        }
    }

    /// Returns full date and time string for detail views
    /// e.g., "Jan 28, 2026 at 2:30 PM"
    var fullFormatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: self)
    }

    /// Returns a short date string
    /// e.g., "Dec 15" or "Dec 15, 2023"
    var shortFormatted: String {
        let calendar = Calendar.current
        let now = Date()
        let thisYear = calendar.component(.year, from: now)
        let dateYear = calendar.component(.year, from: self)

        let formatter = DateFormatter()
        if thisYear == dateYear {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }
        return formatter.string(from: self)
    }
}
