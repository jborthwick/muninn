import Foundation
import SwiftData

@Model
final class Episode {
    @Attribute(.unique) var guid: String
    var title: String
    var episodeDescription: String?
    var audioURL: String
    var duration: TimeInterval?
    var publishedDate: Date?
    var artworkURL: String?  // Episode-specific artwork, falls back to podcast

    // Playback state
    var isPlayed: Bool = false
    var playbackPosition: TimeInterval = 0

    // User actions
    var isStarred: Bool = false

    // Download state
    var localFilePath: String?      // nil = not downloaded, stores just filename (not full path)
    var downloadProgress: Double?   // nil = not downloading, 0-1 = in progress

    /// Returns the full file URL for the downloaded episode
    var localFileURL: URL? {
        guard let filename = localFilePath else { return nil }
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadsPath = documentsPath.appendingPathComponent("Downloads", isDirectory: true)
        return downloadsPath.appendingPathComponent(filename)
    }

    // Relationships
    var podcast: Podcast?

    @Relationship(deleteRule: .cascade, inverse: \QueueItem.episode)
    var queueItems: [QueueItem] = []

    init(
        guid: String,
        title: String,
        audioURL: String,
        episodeDescription: String? = nil,
        duration: TimeInterval? = nil,
        publishedDate: Date? = nil,
        artworkURL: String? = nil
    ) {
        self.guid = guid
        self.title = title
        self.audioURL = audioURL
        self.episodeDescription = episodeDescription
        self.duration = duration
        self.publishedDate = publishedDate
        self.artworkURL = artworkURL
    }

    /// Returns episode artwork URL, or falls back to podcast artwork
    var displayArtworkURL: String? {
        artworkURL ?? podcast?.artworkURL
    }
}
