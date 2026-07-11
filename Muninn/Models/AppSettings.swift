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

    // Transcription settings
    var autoTranscribeEnabledRaw: Int = 1  // 1 = true (default enabled), 0 = false
    var autoGenerateChaptersEnabledRaw: Int = 1

    // Pause recap (on-device summary when playback pauses)
    var pauseRecapEnabledRaw: Int = 1
    var pauseRecapMinutes: Int = 5

    // Smart resume — replay last 15s when resuming after a long pause
    var smartResumeEnabledRaw: Int = 1

    init() {}

    var downloadPreference: DownloadPreference {
        get { DownloadPreference(rawValue: downloadPreferenceRaw) ?? .always }
        set { downloadPreferenceRaw = newValue.rawValue }
    }

    var autoDownloadPreference: DownloadPreference {
        get { DownloadPreference(rawValue: autoDownloadPreferenceRaw) ?? .wifiOnly }
        set { autoDownloadPreferenceRaw = newValue.rawValue }
    }

    var autoTranscribeEnabled: Bool {
        get { autoTranscribeEnabledRaw == 1 }
        set { autoTranscribeEnabledRaw = newValue ? 1 : 0 }
    }

    var autoGenerateChaptersEnabled: Bool {
        get { autoGenerateChaptersEnabledRaw == 1 }
        set { autoGenerateChaptersEnabledRaw = newValue ? 1 : 0 }
    }

    var pauseRecapEnabled: Bool {
        get { pauseRecapEnabledRaw == 1 }
        set { pauseRecapEnabledRaw = newValue ? 1 : 0 }
    }

    var smartResumeEnabled: Bool {
        get { smartResumeEnabledRaw == 1 }
        set { smartResumeEnabledRaw = newValue ? 1 : 0 }
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
