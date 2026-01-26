import Foundation
import SwiftData

@Model
final class AppSettings {
    var globalPlaybackSpeed: Double = 1.0
    var sleepTimerMinutes: Int?   // nil = off
    var sleepTimerEndTime: Date?  // when timer should fire

    // Download settings
    var keepLatestDownloadsPerPodcast: Int = 0  // 0 = unlimited, otherwise 1, 3, 5, 10
    var storageLimitGB: Int = 0                  // 0 = unlimited, otherwise 1, 2, 5, 10

    init() {}

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
