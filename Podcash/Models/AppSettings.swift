import Foundation
import SwiftData

enum DownloadPreference: Int, CaseIterable {
    case always = 0
    case wifiOnly = 1
    case askOnCellular = 2

    var label: String {
        switch self {
        case .always: return "Always"
        case .wifiOnly: return "Only over WiFi"
        case .askOnCellular: return "Ask before using data"
        }
    }
}

@Model
final class AppSettings {
    var globalPlaybackSpeed: Double = 1.0
    var sleepTimerMinutes: Int?   // nil = off
    var sleepTimerEndTime: Date?  // when timer should fire

    // Download settings
    var keepLatestDownloadsPerPodcast: Int = 0  // 0 = unlimited, otherwise 1, 3, 5, 10
    var storageLimitGB: Int = 0                  // 0 = unlimited, otherwise 1, 2, 5, 10

    // Download network preferences (stored as Int for SwiftData compatibility)
    var downloadPreferenceRaw: Int = 0          // DownloadPreference.always
    var autoDownloadPreferenceRaw: Int = 1      // DownloadPreference.wifiOnly (default for auto)

    // Refresh tracking
    var lastGlobalRefresh: Date?

    init() {}

    var downloadPreference: DownloadPreference {
        get { DownloadPreference(rawValue: downloadPreferenceRaw) ?? .always }
        set { downloadPreferenceRaw = newValue.rawValue }
    }

    var autoDownloadPreference: DownloadPreference {
        get { DownloadPreference(rawValue: autoDownloadPreferenceRaw) ?? .wifiOnly }
        set { autoDownloadPreferenceRaw = newValue.rawValue }
    }

    /// Storage limit in bytes (0 = unlimited)
    var storageLimitBytes: Int64 {
        storageLimitGB == 0 ? 0 : Int64(storageLimitGB) * 1024 * 1024 * 1024
    }

    /// Singleton accessor - creates settings if none exist
    static func getOrCreate(context: ModelContext) -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let settings = AppSettings()
        context.insert(settings)
        return settings
    }
}
