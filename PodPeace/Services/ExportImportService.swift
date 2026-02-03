import Foundation
import SwiftData
import UniformTypeIdentifiers
import os

/// Service for exporting and importing app data
@Observable
final class ExportImportService {
    static let shared = ExportImportService()
    
    private let logger = Logger(subsystem: "com.personal.podpeace", category: "ExportImport")
    
    private(set) var isExporting = false
    private(set) var isImporting = false
    private(set) var lastError: String?
    
    private init() {}
    
    // MARK: - Export
    
    /// Export podcasts only (just the feed URLs)
    @MainActor
    func exportPodcastsOnly(context: ModelContext) throws -> URL {
        isExporting = true
        defer { isExporting = false }
        
        logger.info("Starting podcasts-only export")
        
        let podcastDescriptor = FetchDescriptor<Podcast>()
        let podcasts = try context.fetch(podcastDescriptor)
        
        logger.info("Exporting \(podcasts.count) podcasts")
        
        let exportData = PodcastOnlyExport(
            version: 1,
            exportDate: Date(),
            appName: "Pod Peace", // Updated app name
            podcasts: podcasts.map { ExportPodcast(feedURL: $0.feedURL) }
        )
        
        let url = try saveExportFile(exportData, filename: "podcasts-export")
        logger.info("Export saved to: \(url.path)")
        return url
    }
    
    /// Export full data including podcasts, folders, episode states, settings, queue, and downloads
    @MainActor
    func exportFullData(context: ModelContext) throws -> URL {
        isExporting = true
        defer { isExporting = false }
        
        // Fetch all data
        let podcastDescriptor = FetchDescriptor<Podcast>()
        let podcasts = try context.fetch(podcastDescriptor)
        
        let folderDescriptor = FetchDescriptor<Folder>()
        let folders = try context.fetch(folderDescriptor)
        
        let episodeDescriptor = FetchDescriptor<Episode>()
        let episodes = try context.fetch(episodeDescriptor)
        
        let queueDescriptor = FetchDescriptor<QueueItem>(
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let queueItems = try context.fetch(queueDescriptor)
        
        let settings = AppSettings.getOrCreate(context: context)
        
        logger.info("Exporting full data: \(podcasts.count) podcasts, \(folders.count) folders, \(episodes.count) episodes")
        
        // Build full export
        let exportData = FullDataExport(
            version: 1,
            exportDate: Date(),
            appName: "Pod Peace",
            podcasts: podcasts.map { podcast in
                ExportPodcast(
                    feedURL: podcast.feedURL,
                    title: podcast.title,
                    author: podcast.author,
                    artworkURL: podcast.artworkURL,
                    playbackSpeedOverride: podcast.playbackSpeedOverride
                )
            },
            folders: folders.map { folder in
                ExportFolder(
                    id: folder.id.uuidString,
                    name: folder.name,
                    colorHex: folder.colorHex,
                    sortOrder: folder.sortOrder,
                    podcastFeedURLs: folder.podcasts.map { $0.feedURL }
                )
            },
            episodeStates: episodes.compactMap { episode -> ExportEpisodeState? in
                // Only export episodes with meaningful state
                guard episode.isPlayed || episode.isStarred || episode.playbackPosition > 0 || episode.localFilePath != nil else {
                    return nil
                }
                return ExportEpisodeState(
                    guid: episode.guid,
                    podcastFeedURL: episode.podcast?.feedURL ?? "",
                    title: episode.title,
                    isPlayed: episode.isPlayed,
                    isStarred: episode.isStarred,
                    playbackPosition: episode.playbackPosition,
                    isDownloaded: episode.localFilePath != nil
                )
            },
            queue: queueItems.map { item in
                ExportQueueItem(
                    episodeGUID: item.episode?.guid ?? "",
                    podcastFeedURL: item.episode?.podcast?.feedURL ?? "",
                    order: item.sortOrder
                )
            },
            settings: ExportSettings(
                globalPlaybackSpeed: AudioPlayerManager.shared.globalPlaybackSpeed,
                skipForwardInterval: AudioPlayerManager.shared.skipForwardInterval,
                skipBackwardInterval: AudioPlayerManager.shared.skipBackwardInterval,
                keepLatestDownloadsPerPodcast: settings.keepLatestDownloadsPerPodcast,
                storageLimitGB: settings.storageLimitGB,
                downloadPreferenceRaw: settings.downloadPreferenceRaw,
                autoDownloadPreferenceRaw: settings.autoDownloadPreferenceRaw
            ),
            stats: ExportStats(
                totalPodcasts: podcasts.count,
                totalEpisodes: episodes.count,
                playedEpisodes: episodes.filter { $0.isPlayed }.count,
                starredEpisodes: episodes.filter { $0.isStarred }.count,
                downloadedEpisodes: episodes.filter { $0.localFilePath != nil }.count,
                queuedEpisodes: queueItems.count
            )
        )
        
        return try saveExportFile(exportData, filename: "full-export")
    }
    
    // MARK: - Data Deletion
    
    /// Delete all existing data before import
    @MainActor
    private func deleteAllData(context: ModelContext) async throws {
        logger.info("Deleting all existing data")
        
        // Delete in order to respect relationships
        // 1. Queue items (reference episodes)
        let queueDescriptor = FetchDescriptor<QueueItem>()
        let queueItems = try context.fetch(queueDescriptor)
        logger.info("Deleting \(queueItems.count) queue items")
        queueItems.forEach { context.delete($0) }
        
        // 2. Episodes (reference podcasts)
        let episodeDescriptor = FetchDescriptor<Episode>()
        let episodes = try context.fetch(episodeDescriptor)
        logger.info("Deleting \(episodes.count) episodes")
        episodes.forEach { context.delete($0) }
        
        // 3. Folders (reference podcasts)
        let folderDescriptor = FetchDescriptor<Folder>()
        let folders = try context.fetch(folderDescriptor)
        logger.info("Deleting \(folders.count) folders")
        folders.forEach { context.delete($0) }
        
        // 4. Podcasts
        let podcastDescriptor = FetchDescriptor<Podcast>()
        let podcasts = try context.fetch(podcastDescriptor)
        logger.info("Deleting \(podcasts.count) podcasts")
        podcasts.forEach { context.delete($0) }
        
        // 5. Settings (keep settings, just reset to defaults)
        // Don't delete settings, user might want to keep their preferences
        
        try context.save()
        logger.info("All data deleted successfully")
    }
    
    // MARK: - Import
    
    /// Import from a file URL (handles both podcast-only and full exports)
    @MainActor
    func importFromFile(_ url: URL, context: ModelContext, replaceExisting: Bool = false) async throws {
        isImporting = true
        lastError = nil
        defer { isImporting = false }
        
        logger.info("Starting import from: \(url.path), replaceExisting: \(replaceExisting)")
        
        // Delete all existing data if requested
        if replaceExisting {
            try await deleteAllData(context: context)
        }
        
        // Read the file data
        let data: Data
        
        // Try to access the file with security-scoped resource
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            // Try reading directly first
            logger.info("Attempting direct file read")
            data = try Data(contentsOf: url)
            logger.info("Successfully read \(data.count) bytes")
        } catch let readError {
            logger.warning("Direct read failed: \(readError.localizedDescription), trying copy method")
            // If direct read fails, try copying to temp directory first
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: url, to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                data = try Data(contentsOf: tempURL)
                logger.info("Successfully read \(data.count) bytes from temp copy")
            } catch {
                logger.error("Failed to copy and read file: \(error.localizedDescription)")
                throw ExportImportError.accessDenied
            }
        }
        
        // Decode the JSON
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        // Try to decode as full export first
        if let fullExport = try? decoder.decode(FullDataExport.self, from: data) {
            logger.info("Detected full data export from \(fullExport.appName)")
            try await importFullData(fullExport, context: context)
            logger.info("Import completed successfully")
        } else if let podcastExport = try? decoder.decode(PodcastOnlyExport.self, from: data) {
            logger.info("Detected podcasts-only export from \(podcastExport.appName)")
            try await importPodcastsOnly(podcastExport, context: context)
            logger.info("Import completed successfully")
        } else {
            logger.error("Failed to decode export file - invalid format")
            throw ExportImportError.invalidFormat
        }
    }
    
    /// Import podcasts only
    @MainActor
    private func importPodcastsOnly(_ exportData: PodcastOnlyExport, context: ModelContext) async throws {
        let feedService = FeedService.shared
        let existingPodcastDescriptor = FetchDescriptor<Podcast>()
        let existingPodcasts = try context.fetch(existingPodcastDescriptor)
        let existingURLs = Set(existingPodcasts.map { $0.feedURL })
        
        var successCount = 0
        var failCount = 0
        
        for exportPodcast in exportData.podcasts {
            // Skip if already subscribed
            if existingURLs.contains(exportPodcast.feedURL) {
                continue
            }
            
            do {
                // Fetch and add the podcast
                let (podcast, episodes) = try await feedService.fetchPodcast(from: exportPodcast.feedURL)
                context.insert(podcast)
                episodes.forEach { context.insert($0) }
                successCount += 1
            } catch {
                failCount += 1
                continue
            }
        }
        
        try context.save()
        
        if failCount > 0 {
            lastError = "Imported \(successCount) podcasts. Failed to import \(failCount) podcasts."
        }
    }
    
    /// Import full data
    @MainActor
    private func importFullData(_ exportData: FullDataExport, context: ModelContext) async throws {
        let feedService = FeedService.shared
        
        logger.info("Starting full data import with \(exportData.podcasts.count) podcasts")
        
        // 1. Import podcasts first
        let existingPodcastDescriptor = FetchDescriptor<Podcast>()
        let existingPodcasts = try context.fetch(existingPodcastDescriptor)
        var podcastsByURL = Dictionary(uniqueKeysWithValues: existingPodcasts.map { ($0.feedURL, $0) })
        
        var importedCount = 0
        var failedCount = 0
        
        for (index, exportPodcast) in exportData.podcasts.enumerated() {
            logger.info("Importing podcast \(index + 1)/\(exportData.podcasts.count): \(exportPodcast.feedURL)")
            
            if podcastsByURL[exportPodcast.feedURL] == nil {
                do {
                    let (podcast, episodes) = try await feedService.fetchPodcast(from: exportPodcast.feedURL)
                    
                    logger.info("Fetched podcast with \(episodes.count) episodes")
                    
                    // Apply saved playback speed override
                    if let speedOverride = exportPodcast.playbackSpeedOverride {
                        podcast.playbackSpeedOverride = speedOverride
                    }
                    
                    context.insert(podcast)
                    episodes.forEach { episode in
                        context.insert(episode)
                    }
                    
                    // Save after each podcast to avoid memory issues
                    try context.save()
                    
                    podcastsByURL[exportPodcast.feedURL] = podcast
                    importedCount += 1
                    
                    logger.info("Successfully imported podcast \(index + 1)")
                } catch {
                    logger.error("Failed to import podcast: \(error.localizedDescription)")
                    failedCount += 1
                    continue
                }
            } else if let podcast = podcastsByURL[exportPodcast.feedURL],
                      let speedOverride = exportPodcast.playbackSpeedOverride {
                // Update existing podcast's speed override
                podcast.playbackSpeedOverride = speedOverride
            }
        }
        
        logger.info("Imported \(importedCount) podcasts, \(failedCount) failed")
        try context.save()
        
        // 2. Import folders
        logger.info("Importing \(exportData.folders.count) folders")
        let existingFolderDescriptor = FetchDescriptor<Folder>()
        let existingFolders = try context.fetch(existingFolderDescriptor)
        var foldersById = Dictionary(uniqueKeysWithValues: existingFolders.map { ($0.id.uuidString, $0) })
        
        // Re-fetch podcasts to get fresh references after save
        let podcastDescriptor = FetchDescriptor<Podcast>()
        let allPodcasts = try context.fetch(podcastDescriptor)
        podcastsByURL = Dictionary(uniqueKeysWithValues: allPodcasts.map { ($0.feedURL, $0) })
        
        for exportFolder in exportData.folders {
            if let existingFolder = foldersById[exportFolder.id] {
                // Update existing folder
                existingFolder.name = exportFolder.name
                existingFolder.colorHex = exportFolder.colorHex
                existingFolder.sortOrder = exportFolder.sortOrder
                existingFolder.podcasts = exportFolder.podcastFeedURLs.compactMap { podcastsByURL[$0] }
            } else {
                // Create new folder
                let folder = Folder(name: exportFolder.name, colorHex: exportFolder.colorHex)
                folder.sortOrder = exportFolder.sortOrder
                folder.podcasts = exportFolder.podcastFeedURLs.compactMap { podcastsByURL[$0] }
                if let uuid = UUID(uuidString: exportFolder.id) {
                    folder.id = uuid
                }
                context.insert(folder)
                foldersById[exportFolder.id] = folder
            }
        }
        
        try context.save()
        logger.info("Folders imported successfully")
        
        // 3. Import episode states
        logger.info("Importing episode states for \(exportData.episodeStates.count) episodes")
        let episodeDescriptor = FetchDescriptor<Episode>()
        let allEpisodes = try context.fetch(episodeDescriptor)
        logger.info("Found \(allEpisodes.count) episodes in database")
        
        let episodesByGUID = Dictionary(uniqueKeysWithValues: allEpisodes.map { ($0.guid, $0) })
        
        var statesApplied = 0
        for state in exportData.episodeStates {
            if let episode = episodesByGUID[state.guid] {
                episode.isPlayed = state.isPlayed
                episode.isStarred = state.isStarred
                episode.playbackPosition = state.playbackPosition
                statesApplied += 1
                // Note: We don't restore downloads, user needs to re-download
            }
        }
        
        logger.info("Applied states to \(statesApplied) episodes")
        try context.save()
        
        // 4. Import queue
        logger.info("Importing queue with \(exportData.queue.count) items")
        // Clear existing queue first
        let existingQueueDescriptor = FetchDescriptor<QueueItem>()
        let existingQueue = try context.fetch(existingQueueDescriptor)
        existingQueue.forEach { context.delete($0) }
        
        var queueItemsAdded = 0
        for exportQueueItem in exportData.queue {
            if let episode = episodesByGUID[exportQueueItem.episodeGUID] {
                let queueItem = QueueItem(episode: episode, sortOrder: exportQueueItem.order)
                context.insert(queueItem)
                queueItemsAdded += 1
            }
        }
        
        logger.info("Added \(queueItemsAdded) items to queue")
        try context.save()
        
        // 5. Import settings
        logger.info("Importing settings")
        let settings = AppSettings.getOrCreate(context: context)
        settings.keepLatestDownloadsPerPodcast = exportData.settings.keepLatestDownloadsPerPodcast
        settings.storageLimitGB = exportData.settings.storageLimitGB
        settings.downloadPreferenceRaw = exportData.settings.downloadPreferenceRaw
        settings.autoDownloadPreferenceRaw = exportData.settings.autoDownloadPreferenceRaw
        
        AudioPlayerManager.shared.globalPlaybackSpeed = exportData.settings.globalPlaybackSpeed
        AudioPlayerManager.shared.skipForwardInterval = exportData.settings.skipForwardInterval
        AudioPlayerManager.shared.skipBackwardInterval = exportData.settings.skipBackwardInterval
        
        try context.save()
        
        // Final verification
        let finalEpisodeCount = try context.fetch(FetchDescriptor<Episode>()).count
        let finalPodcastCount = try context.fetch(FetchDescriptor<Podcast>()).count
        logger.info("Import complete! Final counts - Podcasts: \(finalPodcastCount), Episodes: \(finalEpisodeCount)")
        
        if failedCount > 0 {
            lastError = "Import completed with \(failedCount) failed podcast(s). Successfully imported \(importedCount) podcast(s) with \(finalEpisodeCount) episodes."
        }
    }
    
    // MARK: - Helper Methods
    
    private func saveExportFile<T: Encodable>(_ data: T, filename: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let jsonData = try encoder.encode(data)
        
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = tempDir.appendingPathComponent("\(filename)-\(timestamp).json")
        
        try jsonData.write(to: fileURL)
        return fileURL
    }
}

// MARK: - Export Data Models

struct PodcastOnlyExport: Codable {
    let version: Int
    let exportDate: Date
    let appName: String
    let podcasts: [ExportPodcast]
}

struct FullDataExport: Codable {
    let version: Int
    let exportDate: Date
    let appName: String
    let podcasts: [ExportPodcast]
    let folders: [ExportFolder]
    let episodeStates: [ExportEpisodeState]
    let queue: [ExportQueueItem]
    let settings: ExportSettings
    let stats: ExportStats
}

struct ExportPodcast: Codable {
    let feedURL: String
    var title: String?
    var author: String?
    var artworkURL: String?
    var playbackSpeedOverride: Double?
}

struct ExportFolder: Codable {
    let id: String
    let name: String
    let colorHex: String?
    let sortOrder: Int
    let podcastFeedURLs: [String]
}

struct ExportEpisodeState: Codable {
    let guid: String
    let podcastFeedURL: String
    let title: String
    let isPlayed: Bool
    let isStarred: Bool
    let playbackPosition: TimeInterval
    let isDownloaded: Bool
}

struct ExportQueueItem: Codable {
    let episodeGUID: String
    let podcastFeedURL: String
    let order: Int
}

struct ExportSettings: Codable {
    let globalPlaybackSpeed: Double
    let skipForwardInterval: TimeInterval
    let skipBackwardInterval: TimeInterval
    let keepLatestDownloadsPerPodcast: Int
    let storageLimitGB: Int
    let downloadPreferenceRaw: Int
    let autoDownloadPreferenceRaw: Int
}

struct ExportStats: Codable {
    let totalPodcasts: Int
    let totalEpisodes: Int
    let playedEpisodes: Int
    let starredEpisodes: Int
    let downloadedEpisodes: Int
    let queuedEpisodes: Int
}

// MARK: - Errors

enum ExportImportError: LocalizedError {
    case accessDenied
    case invalidFormat
    case exportFailed
    case importFailed
    
    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Unable to access the file"
        case .invalidFormat:
            return "Invalid export file format"
        case .exportFailed:
            return "Failed to export data"
        case .importFailed:
            return "Failed to import data"
        }
    }
}
