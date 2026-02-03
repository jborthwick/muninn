import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Service for exporting and importing app data
@Observable
final class ExportImportService {
    static let shared = ExportImportService()
    
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
        
        let podcastDescriptor = FetchDescriptor<Podcast>()
        let podcasts = try context.fetch(podcastDescriptor)
        
        let exportData = PodcastOnlyExport(
            version: 1,
            exportDate: Date(),
            appName: "Podcash", // Will work with both old and new app names
            podcasts: podcasts.map { ExportPodcast(feedURL: $0.feedURL) }
        )
        
        return try saveExportFile(exportData, filename: "podcasts-export")
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
        
        // Build full export
        let exportData = FullDataExport(
            version: 1,
            exportDate: Date(),
            appName: "Podcash",
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
    
    // MARK: - Import
    
    /// Import from a file URL (handles both podcast-only and full exports)
    @MainActor
    func importFromFile(_ url: URL, context: ModelContext) async throws {
        isImporting = true
        lastError = nil
        defer { isImporting = false }
        
        // Read the file
        guard url.startAccessingSecurityScopedResource() else {
            throw ExportImportError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        let data = try Data(contentsOf: url)
        
        // Try to decode as full export first
        if let fullExport = try? JSONDecoder().decode(FullDataExport.self, from: data) {
            try await importFullData(fullExport, context: context)
        } else if let podcastExport = try? JSONDecoder().decode(PodcastOnlyExport.self, from: data) {
            try await importPodcastsOnly(podcastExport, context: context)
        } else {
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
        
        // 1. Import podcasts first
        let existingPodcastDescriptor = FetchDescriptor<Podcast>()
        let existingPodcasts = try context.fetch(existingPodcastDescriptor)
        var podcastsByURL = Dictionary(uniqueKeysWithValues: existingPodcasts.map { ($0.feedURL, $0) })
        
        for exportPodcast in exportData.podcasts {
            if podcastsByURL[exportPodcast.feedURL] == nil {
                do {
                    let (podcast, episodes) = try await feedService.fetchPodcast(from: exportPodcast.feedURL)
                    
                    // Apply saved playback speed override
                    if let speedOverride = exportPodcast.playbackSpeedOverride {
                        podcast.playbackSpeedOverride = speedOverride
                    }
                    
                    context.insert(podcast)
                    episodes.forEach { context.insert($0) }
                    podcastsByURL[exportPodcast.feedURL] = podcast
                } catch {
                    // Continue with other podcasts if one fails
                    continue
                }
            } else if let podcast = podcastsByURL[exportPodcast.feedURL],
                      let speedOverride = exportPodcast.playbackSpeedOverride {
                // Update existing podcast's speed override
                podcast.playbackSpeedOverride = speedOverride
            }
        }
        
        try context.save()
        
        // 2. Import folders
        let existingFolderDescriptor = FetchDescriptor<Folder>()
        let existingFolders = try context.fetch(existingFolderDescriptor)
        var foldersById = Dictionary(uniqueKeysWithValues: existingFolders.map { ($0.id.uuidString, $0) })
        
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
        
        // 3. Import episode states
        let episodeDescriptor = FetchDescriptor<Episode>()
        let allEpisodes = try context.fetch(episodeDescriptor)
        let episodesByGUID = Dictionary(uniqueKeysWithValues: allEpisodes.map { ($0.guid, $0) })
        
        for state in exportData.episodeStates {
            if let episode = episodesByGUID[state.guid] {
                episode.isPlayed = state.isPlayed
                episode.isStarred = state.isStarred
                episode.playbackPosition = state.playbackPosition
                // Note: We don't restore downloads, user needs to re-download
            }
        }
        
        try context.save()
        
        // 4. Import queue
        // Clear existing queue first
        let existingQueueDescriptor = FetchDescriptor<QueueItem>()
        let existingQueue = try context.fetch(existingQueueDescriptor)
        existingQueue.forEach { context.delete($0) }
        
        for exportQueueItem in exportData.queue {
            if let episode = episodesByGUID[exportQueueItem.episodeGUID] {
                let queueItem = QueueItem(episode: episode, sortOrder: exportQueueItem.order)
                context.insert(queueItem)
            }
        }
        
        try context.save()
        
        // 5. Import settings
        let settings = AppSettings.getOrCreate(context: context)
        settings.keepLatestDownloadsPerPodcast = exportData.settings.keepLatestDownloadsPerPodcast
        settings.storageLimitGB = exportData.settings.storageLimitGB
        settings.downloadPreferenceRaw = exportData.settings.downloadPreferenceRaw
        settings.autoDownloadPreferenceRaw = exportData.settings.autoDownloadPreferenceRaw
        
        AudioPlayerManager.shared.globalPlaybackSpeed = exportData.settings.globalPlaybackSpeed
        AudioPlayerManager.shared.skipForwardInterval = exportData.settings.skipForwardInterval
        AudioPlayerManager.shared.skipBackwardInterval = exportData.settings.skipBackwardInterval
        
        try context.save()
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
