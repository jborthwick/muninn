import Foundation
import SwiftData
import os

/// Syncs app data via iCloud Drive (not CloudKit)
@Observable
final class SyncService {
    static let shared = SyncService()

    private let logger = AppLogger.sync

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var syncError: String?
    private(set) var isCloudAvailable = false

    private let syncFileName = "MuninnSync.json"
    private var metadataQuery: NSMetadataQuery?
    private var localContainer: URL?
    private var cloudContainer: URL?
    private var cloudChangeObserver: NSObjectProtocol?

    // Debounce timer for change-triggered syncs
    private var syncDebounceTask: Task<Void, Never>?
    private let syncDebounceInterval: TimeInterval = 5.0 // Wait 5 seconds after last change

    private init() {
        setupContainers()
    }

    deinit {
        syncDebounceTask?.cancel()
        if let observer = cloudChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        metadataQuery?.stop()
    }

    // MARK: - Change-Triggered Sync

    /// Call this when data changes to trigger a debounced sync
    func scheduleSync(context: ModelContext) {
        // Cancel any pending sync
        syncDebounceTask?.cancel()

        // Schedule new sync after debounce interval
        syncDebounceTask = Task {
            try? await Task.sleep(for: .seconds(syncDebounceInterval))

            guard !Task.isCancelled else { return }

            await syncNow(context: context)
        }
    }

    // MARK: - Setup

    private func setupContainers() {
        // Local fallback
        localContainer = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

        // Check for iCloud availability
        if let cloudURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.personal.muninn") {
            cloudContainer = cloudURL.appendingPathComponent("Documents", isDirectory: true)

            // Create Documents folder if needed
            if let container = cloudContainer {
                try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            }

            isCloudAvailable = true
            startMonitoringCloudChanges()
            logger.info("iCloud container available at: \(cloudURL.path)")
        } else {
            isCloudAvailable = false
            logger.info("iCloud not available - using local storage only")
        }
    }

    // MARK: - Cloud Monitoring

    private func startMonitoringCloudChanges() {
        guard isCloudAvailable else { return }

        metadataQuery = NSMetadataQuery()
        metadataQuery?.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        metadataQuery?.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, syncFileName)

        cloudChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: metadataQuery,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("Cloud sync file changed - will merge on next sync")
        }

        metadataQuery?.start()
    }

    // MARK: - Sync Operations

    func syncNow(context: ModelContext) async {
        guard !isSyncing else { return }

        await MainActor.run {
            isSyncing = true
            syncError = nil
        }

        do {
            // Read cloud data first
            let cloudData = try await readCloudData()

            // Export local data
            let localData = try await exportLocalData(context: context)

            // Merge data (cloud wins for conflicts based on timestamp)
            let mergedData = mergeData(local: localData, cloud: cloudData)

            // Import merged data back to local
            try await importData(mergedData, context: context)

            // Write merged data to cloud
            try await writeCloudData(mergedData)

            await MainActor.run {
                lastSyncDate = Date()
                isSyncing = false
            }
        } catch {
            await MainActor.run {
                syncError = error.localizedDescription
                isSyncing = false
            }
            logger.error("Sync error: \(error.localizedDescription)")
        }
    }

    // MARK: - Data Export

    @MainActor
    private func exportLocalData(context: ModelContext) async throws -> SyncData {
        let podcastDescriptor = FetchDescriptor<Podcast>()
        let podcasts = try context.fetch(podcastDescriptor)

        let folderDescriptor = FetchDescriptor<Folder>()
        let folders = try context.fetch(folderDescriptor)

        let episodeDescriptor = FetchDescriptor<Episode>()
        let episodes = try context.fetch(episodeDescriptor)

        // Build sync data
        var syncData = SyncData(timestamp: Date())

        // Export podcasts
        syncData.podcasts = podcasts.map { podcast in
            SyncPodcast(
                feedURL: podcast.feedURL,
                playbackSpeedOverride: podcast.playbackSpeedOverride
            )
        }

        // Export folders
        syncData.folders = folders.map { folder in
            SyncFolder(
                id: folder.id.uuidString,
                name: folder.name,
                colorHex: folder.colorHex,
                sortOrder: folder.sortOrder,
                podcastFeedURLs: folder.podcasts.map { $0.feedURL }
            )
        }

        // Export episode states (only for episodes with meaningful state)
        syncData.episodeStates = episodes.compactMap { episode -> SyncEpisodeState? in
            guard episode.isPlayed || episode.isStarred || episode.playbackPosition > 0 else {
                return nil
            }
            return SyncEpisodeState(
                guid: episode.guid,
                podcastFeedURL: episode.podcast?.feedURL ?? "",
                isPlayed: episode.isPlayed,
                isStarred: episode.isStarred,
                playbackPosition: episode.playbackPosition
            )
        }

        // Export settings
        syncData.settings = SyncSettings(
            globalPlaybackSpeed: AudioPlayerManager.shared.globalPlaybackSpeed,
            skipForwardInterval: AudioPlayerManager.shared.skipForwardInterval,
            skipBackwardInterval: AudioPlayerManager.shared.skipBackwardInterval
        )

        return syncData
    }

    // MARK: - Data Import

    @MainActor
    private func importData(_ data: SyncData, context: ModelContext) async throws {
        // Fetch existing data
        let podcastDescriptor = FetchDescriptor<Podcast>()
        let existingPodcasts = try context.fetch(podcastDescriptor)
        let podcastsByURL = Dictionary(uniqueKeysWithValues: existingPodcasts.map { ($0.feedURL, $0) })

        let folderDescriptor = FetchDescriptor<Folder>()
        let existingFolders = try context.fetch(folderDescriptor)
        let foldersById = Dictionary(uniqueKeysWithValues: existingFolders.compactMap { folder -> (String, Folder)? in
            return (folder.id.uuidString, folder)
        })

        // Import podcasts (add new ones)
        for syncPodcast in data.podcasts {
            if let existing = podcastsByURL[syncPodcast.feedURL] {
                // Update speed override if set
                if let speed = syncPodcast.playbackSpeedOverride {
                    existing.playbackSpeedOverride = speed
                }
            }
            // Note: We don't auto-subscribe to podcasts from cloud
            // User needs to manually add podcasts on each device
        }

        // Import folders
        for syncFolder in data.folders {
            if let existing = foldersById[syncFolder.id] {
                // Update existing folder
                existing.name = syncFolder.name
                existing.colorHex = syncFolder.colorHex
                existing.sortOrder = syncFolder.sortOrder

                // Update podcast assignments
                existing.podcasts = syncFolder.podcastFeedURLs.compactMap { podcastsByURL[$0] }
            } else {
                // Create new folder
                let newFolder = Folder(name: syncFolder.name, colorHex: syncFolder.colorHex)
                newFolder.sortOrder = syncFolder.sortOrder
                newFolder.podcasts = syncFolder.podcastFeedURLs.compactMap { podcastsByURL[$0] }
                context.insert(newFolder)
            }
        }

        // Import episode states
        let episodeDescriptor = FetchDescriptor<Episode>()
        let allEpisodes = try context.fetch(episodeDescriptor)
        let episodesByGUID = Dictionary(uniqueKeysWithValues: allEpisodes.map { ($0.guid, $0) })

        for state in data.episodeStates {
            if let episode = episodesByGUID[state.guid] {
                episode.isPlayed = state.isPlayed
                episode.isStarred = state.isStarred
                episode.playbackPosition = state.playbackPosition
            }
        }

        // Import settings
        if let settings = data.settings {
            AudioPlayerManager.shared.globalPlaybackSpeed = settings.globalPlaybackSpeed
            AudioPlayerManager.shared.skipForwardInterval = settings.skipForwardInterval
            AudioPlayerManager.shared.skipBackwardInterval = settings.skipBackwardInterval
        }

        try context.save()
    }

    // MARK: - Cloud Storage

    private var syncFileURL: URL? {
        if isCloudAvailable, let cloud = cloudContainer {
            return cloud.appendingPathComponent(syncFileName)
        }
        return localContainer?.appendingPathComponent(syncFileName)
    }

    private func readCloudData() async throws -> SyncData? {
        guard let url = syncFileURL else { return nil }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SyncData.self, from: data)
    }

    private func writeCloudData(_ syncData: SyncData) async throws {
        guard let url = syncFileURL else { return }

        let data = try JSONEncoder().encode(syncData)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Merge Logic

    private func mergeData(local: SyncData, cloud: SyncData?) -> SyncData {
        guard let cloud = cloud else { return local }

        // Use newer timestamp as base, merge the other
        let (base, other) = local.timestamp > cloud.timestamp ? (local, cloud) : (cloud, local)

        var merged = base

        // Merge podcasts (union of both)
        let allPodcastURLs = Set(base.podcasts.map { $0.feedURL }).union(other.podcasts.map { $0.feedURL })
        merged.podcasts = allPodcastURLs.compactMap { url in
            // Prefer base data, fall back to other
            base.podcasts.first { $0.feedURL == url } ??
            other.podcasts.first { $0.feedURL == url }
        }

        // Merge folders (base wins for conflicts, add unique from other)
        let baseFolderIds = Set(base.folders.map { $0.id })
        let otherUniqueFolders = other.folders.filter { !baseFolderIds.contains($0.id) }
        merged.folders = base.folders + otherUniqueFolders

        // Merge episode states (most recent state wins)
        var statesByGUID = Dictionary(uniqueKeysWithValues: base.episodeStates.map { ($0.guid, $0) })
        for state in other.episodeStates {
            if statesByGUID[state.guid] == nil {
                statesByGUID[state.guid] = state
            }
            // Could add more sophisticated merging based on individual state timestamps
        }
        merged.episodeStates = Array(statesByGUID.values)

        return merged
    }
}

// MARK: - Sync Data Models

struct SyncData: Codable {
    var timestamp: Date
    var podcasts: [SyncPodcast] = []
    var folders: [SyncFolder] = []
    var episodeStates: [SyncEpisodeState] = []
    var settings: SyncSettings?
}

struct SyncPodcast: Codable {
    var feedURL: String
    var playbackSpeedOverride: Double?
}

struct SyncFolder: Codable {
    var id: String
    var name: String
    var colorHex: String?
    var sortOrder: Int
    var podcastFeedURLs: [String]
}

struct SyncEpisodeState: Codable {
    var guid: String
    var podcastFeedURL: String
    var isPlayed: Bool
    var isStarred: Bool
    var playbackPosition: TimeInterval
}

struct SyncSettings: Codable {
    var globalPlaybackSpeed: Double
    var skipForwardInterval: TimeInterval
    var skipBackwardInterval: TimeInterval
}
