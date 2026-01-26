import Foundation
import SwiftData
import os

/// Manages automatic cleanup of downloaded episodes
final class DownloadCleanupService {
    static let shared = DownloadCleanupService()

    private let logger = AppLogger.download
    private let fileManager = FileManager.default

    private init() {}

    // MARK: - Public Methods

    /// Called when an episode finishes playing - deletes the download if not protected
    func onEpisodeCompleted(_ episode: Episode, context: ModelContext) {
        // Don't delete if starred or in queue
        guard !episode.isStarred && !isInQueue(episode, context: context) else {
            logger.info("Episode completed but protected (starred or queued): \(episode.title)")
            return
        }

        // Delete the download
        if episode.localFilePath != nil {
            DownloadManager.shared.deleteDownload(episode)
            logger.info("Auto-deleted completed episode: \(episode.title)")
        }

        // Also enforce limits
        enforceStorageLimit(context: context)
    }

    /// Checks if an episode is "effectively completed" (played or nearly finished)
    /// Nearly finished = within last 5% or last 2 minutes of duration
    func isEffectivelyCompleted(_ episode: Episode) -> Bool {
        if episode.isPlayed {
            return true
        }

        guard let duration = episode.duration, duration > 0 else {
            return false
        }

        let position = episode.playbackPosition
        let remaining = duration - position

        // Within last 5% or last 2 minutes
        let nearEndByPercent = position >= duration * 0.95
        let nearEndByTime = remaining <= 120 // 2 minutes

        return nearEndByPercent || nearEndByTime
    }

    /// Enforces storage limit by deleting oldest non-protected downloads
    func enforceStorageLimit(context: ModelContext) {
        let settings = AppSettings.getOrCreate(context: context)
        let limitBytes = settings.storageLimitBytes

        guard limitBytes > 0 else { return } // No limit

        let currentSize = DownloadManager.shared.totalDownloadSize(context: context)

        guard currentSize > limitBytes else { return } // Under limit

        logger.info("Storage limit exceeded: \(self.formatBytes(currentSize)) / \(self.formatBytes(limitBytes))")

        // Get deletable episodes (oldest first, exclude protected)
        let deletableEpisodes = getDeletableEpisodes(context: context)
            .sorted { ($0.publishedDate ?? .distantPast) < ($1.publishedDate ?? .distantPast) }

        var freedBytes: Int64 = 0
        let bytesToFree = currentSize - limitBytes

        for episode in deletableEpisodes {
            guard freedBytes < bytesToFree else { break }

            if let fileURL = episode.localFileURL {
                if let size = try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 {
                    freedBytes += size
                }
                DownloadManager.shared.deleteDownload(episode)
                logger.info("Deleted to free space: \(episode.title)")
            }
        }

        logger.info("Freed \(self.formatBytes(freedBytes)) of storage")
    }

    /// Enforces per-podcast download limit
    func enforcePerPodcastLimit(for podcast: Podcast, context: ModelContext) {
        let settings = AppSettings.getOrCreate(context: context)
        let limit = settings.keepLatestDownloadsPerPodcast

        guard limit > 0 else { return } // No limit

        // Get downloaded episodes for this podcast, sorted by date (newest first)
        let downloadedEpisodes = podcast.episodes
            .filter { $0.localFilePath != nil }
            .sorted { ($0.publishedDate ?? .distantPast) > ($1.publishedDate ?? .distantPast) }

        // Skip protected episodes and keep track of how many we're keeping
        var keptCount = 0
        for episode in downloadedEpisodes {
            let isProtected = episode.isStarred || isInQueue(episode, context: context)

            if isProtected {
                // Protected episodes don't count toward limit
                continue
            }

            keptCount += 1

            if keptCount > limit {
                // Delete this download
                DownloadManager.shared.deleteDownload(episode)
                logger.info("Deleted to enforce per-podcast limit: \(episode.title)")
            }
        }
    }

    /// Deletes all downloads except protected ones
    func deleteAllUnprotectedDownloads(context: ModelContext) {
        let deletableEpisodes = getDeletableEpisodes(context: context)

        for episode in deletableEpisodes {
            DownloadManager.shared.deleteDownload(episode)
        }

        logger.info("Deleted \(deletableEpisodes.count) unprotected downloads")
    }

    // MARK: - Private Methods

    private func getDeletableEpisodes(context: ModelContext) -> [Episode] {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.localFilePath != nil }
        )

        guard let episodes = try? context.fetch(descriptor) else { return [] }

        // Filter out protected episodes (starred or in queue)
        // Prioritize effectively completed episodes for deletion
        return episodes
            .filter { !$0.isStarred && !isInQueue($0, context: context) }
            .sorted { episode1, episode2 in
                // Effectively completed episodes should be deleted first
                let completed1 = isEffectivelyCompleted(episode1)
                let completed2 = isEffectivelyCompleted(episode2)

                if completed1 != completed2 {
                    return completed1 // Completed episodes come first (for deletion)
                }

                // Then by oldest publish date
                let date1 = episode1.publishedDate ?? .distantPast
                let date2 = episode2.publishedDate ?? .distantPast
                return date1 < date2
            }
    }

    private func isInQueue(_ episode: Episode, context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<QueueItem>()
        guard let queueItems = try? context.fetch(descriptor) else { return false }

        return queueItems.contains { $0.episode?.guid == episode.guid }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
