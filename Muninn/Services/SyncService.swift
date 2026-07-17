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

    /// Local tombstones for deletions that haven't been written to the cloud file yet.
    private static let pendingDeletedFoldersKey = "syncPendingDeletedFolderIds"
    private static let pendingDeletedPlaylistsKey = "syncPendingDeletedPlaylistIds"

    private init() {
        setupContainers()
    }

    // MARK: - Deletion Tombstones

    /// Deletes a folder locally, records a sync tombstone, and schedules a sync.
    func deleteFolder(_ folder: Folder, context: ModelContext) {
        deleteFolders([folder], context: context)
    }

    /// Deletes folders locally, records sync tombstones, and schedules a sync.
    func deleteFolders(_ folders: [Folder], context: ModelContext) {
        guard !folders.isEmpty else { return }
        for folder in folders {
            appendPendingDeletion(folder.id, key: Self.pendingDeletedFoldersKey)
            context.delete(folder)
        }
        try? context.save()
        scheduleSync(context: context)
    }

    /// Record a playlist deletion so sync won't resurrect it from an older cloud snapshot.
    func recordPlaylistDeletion(_ id: UUID) {
        appendPendingDeletion(id, key: Self.pendingDeletedPlaylistsKey)
    }

    private var pendingDeletedFolderIds: [String] {
        pendingIds(forKey: Self.pendingDeletedFoldersKey)
    }

    private var pendingDeletedPlaylistIds: [String] {
        pendingIds(forKey: Self.pendingDeletedPlaylistsKey)
    }

    private func pendingIds(forKey key: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    private func appendPendingDeletion(_ id: UUID, key: String) {
        var ids = pendingIds(forKey: key)
        let value = id.uuidString
        guard !ids.contains(value) else { return }
        ids.append(value)
        UserDefaults.standard.set(ids, forKey: key)
    }

    private func clearPendingDeletions() {
        UserDefaults.standard.removeObject(forKey: Self.pendingDeletedFoldersKey)
        UserDefaults.standard.removeObject(forKey: Self.pendingDeletedPlaylistsKey)
    }

    deinit {
        syncDebounceTask?.cancel()
        if let observer = cloudChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        metadataQuery?.stop()
    }

    // MARK: - Reset

    /// Overwrites the iCloud sync file with empty data. Call after a full local reset
    /// so the cloud doesn't resurrect old subscriptions on the next merge.
    func clearSyncData() async {
        clearPendingDeletions()
        let empty = SyncData(timestamp: Date())
        try? await writeCloudData(empty)
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
        // Using nil uses the first iCloud container in your entitlements
        if let cloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
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

            // Keep local tombstones in sync with what we just wrote so a later
            // failed cloud read can't drop deletion history on the next export.
            UserDefaults.standard.set(mergedData.deletedFolderIds, forKey: Self.pendingDeletedFoldersKey)
            UserDefaults.standard.set(mergedData.deletedPlaylistIds, forKey: Self.pendingDeletedPlaylistsKey)

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

        let playlistDescriptor = FetchDescriptor<Playlist>()
        let playlists = try context.fetch(playlistDescriptor)

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

        // Export playlists
        syncData.playlists = playlists.map { playlist in
            let sortedItems = playlist.items.sorted { $0.sortOrder < $1.sortOrder }
            return SyncPlaylist(
                id: playlist.id.uuidString,
                name: playlist.name,
                colorHex: playlist.colorHex,
                sortOrder: playlist.sortOrder,
                episodeGUIDs: sortedItems.compactMap { $0.episode?.guid }
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

        // Include local deletion tombstones so merges honor deletes
        syncData.deletedFolderIds = pendingDeletedFolderIds
        syncData.deletedPlaylistIds = pendingDeletedPlaylistIds

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
        var foldersById = Dictionary(uniqueKeysWithValues: existingFolders.compactMap { folder -> (String, Folder)? in
            return (folder.id.uuidString, folder)
        })

        let playlistDescriptor = FetchDescriptor<Playlist>()
        let existingPlaylists = try context.fetch(playlistDescriptor)
        var playlistsById = Dictionary(uniqueKeysWithValues: existingPlaylists.compactMap { playlist -> (String, Playlist)? in
            return (playlist.id.uuidString, playlist)
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

        let deletedFolderIds = Set(data.deletedFolderIds)
        let deletedPlaylistIds = Set(data.deletedPlaylistIds)

        // Apply folder deletions from tombstones before creating/updating
        for folder in existingFolders {
            let id = folder.id.uuidString
            if deletedFolderIds.contains(id) {
                context.delete(folder)
                foldersById.removeValue(forKey: id)
            }
        }

        // Import folders
        for syncFolder in data.folders {
            guard !deletedFolderIds.contains(syncFolder.id) else { continue }

            if let existing = foldersById[syncFolder.id] {
                // Update existing folder
                existing.name = syncFolder.name
                existing.colorHex = syncFolder.colorHex
                existing.sortOrder = syncFolder.sortOrder

                // Update podcast assignments
                existing.podcasts = syncFolder.podcastFeedURLs.compactMap { podcastsByURL[$0] }
            } else {
                // Create new folder — preserve sync ID to avoid duplicates on later merges
                let newFolder = Folder(name: syncFolder.name, colorHex: syncFolder.colorHex)
                if let uuid = UUID(uuidString: syncFolder.id) {
                    newFolder.id = uuid
                }
                newFolder.sortOrder = syncFolder.sortOrder
                newFolder.podcasts = syncFolder.podcastFeedURLs.compactMap { podcastsByURL[$0] }
                context.insert(newFolder)
                foldersById[syncFolder.id] = newFolder
            }
        }

        // Import episode states
        let episodeDescriptor = FetchDescriptor<Episode>()
        let allEpisodes = try context.fetch(episodeDescriptor)
        let episodesByGUID = Dictionary(uniqueKeysWithValues: allEpisodes.map { ($0.guid, $0) })

        // Apply playlist deletions from tombstones before creating/updating
        for playlist in existingPlaylists {
            let id = playlist.id.uuidString
            if deletedPlaylistIds.contains(id) {
                for item in playlist.items {
                    context.delete(item)
                }
                context.delete(playlist)
                playlistsById.removeValue(forKey: id)
            }
        }

        // Import playlists
        for syncPlaylist in data.playlists {
            guard !deletedPlaylistIds.contains(syncPlaylist.id) else { continue }

            let playlist: Playlist
            if let existing = playlistsById[syncPlaylist.id] {
                existing.name = syncPlaylist.name
                existing.colorHex = syncPlaylist.colorHex
                existing.sortOrder = syncPlaylist.sortOrder
                playlist = existing

                for item in existing.items {
                    context.delete(item)
                }
            } else {
                let newPlaylist = Playlist(name: syncPlaylist.name, colorHex: syncPlaylist.colorHex)
                newPlaylist.sortOrder = syncPlaylist.sortOrder
                if let uuid = UUID(uuidString: syncPlaylist.id) {
                    newPlaylist.id = uuid
                }
                context.insert(newPlaylist)
                playlistsById[syncPlaylist.id] = newPlaylist
                playlist = newPlaylist
            }

            for (index, guid) in syncPlaylist.episodeGUIDs.enumerated() {
                if let episode = episodesByGUID[guid] {
                    let item = PlaylistItem(episode: episode, sortOrder: index)
                    item.playlist = playlist
                    playlist.items.append(item)
                    context.insert(item)
                }
            }
        }

        // Import episode states
        let currentGUID = AudioPlayerManager.shared.currentEpisode?.guid
        for state in data.episodeStates {
            if let episode = episodesByGUID[state.guid] {
                episode.isPlayed = state.isPlayed
                episode.isStarred = state.isStarred
                // Don't clobber an in-progress / restored playhead with a stale cloud zero
                if state.guid == currentGUID {
                    episode.playbackPosition = max(episode.playbackPosition, state.playbackPosition)
                } else {
                    episode.playbackPosition = state.playbackPosition
                }
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
        guard !data.isEmpty else {
            logger.warning("Sync file is empty — treating as no cloud data")
            return nil
        }

        do {
            return try JSONDecoder().decode(SyncData.self, from: data)
        } catch {
            logger.error("Failed to decode sync file: \(error.localizedDescription)")
            return nil
        }
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
        let (newer, older) = local.timestamp > cloud.timestamp ? (local, cloud) : (cloud, local)

        var merged = newer

        // Merge podcasts (union of both)
        let allPodcastURLs = Set(newer.podcasts.map { $0.feedURL }).union(older.podcasts.map { $0.feedURL })
        merged.podcasts = allPodcastURLs.compactMap { url in
            // Prefer newer data, fall back to older
            newer.podcasts.first { $0.feedURL == url } ??
            older.podcasts.first { $0.feedURL == url }
        }

        // Explicit tombstones only — never infer deletes from "missing on newer side"
        // (a fresh/empty device would otherwise wipe cloud folders).
        let (mergedFolders, deletedFolderIds) = mergeById(
            newer: newer.folders,
            older: older.folders,
            localDeletedIds: local.deletedFolderIds,
            cloudDeletedIds: cloud.deletedFolderIds
        )
        merged.folders = mergedFolders
        merged.deletedFolderIds = deletedFolderIds

        let (mergedPlaylists, deletedPlaylistIds) = mergeById(
            newer: newer.playlists,
            older: older.playlists,
            localDeletedIds: local.deletedPlaylistIds,
            cloudDeletedIds: cloud.deletedPlaylistIds
        )
        merged.playlists = mergedPlaylists
        merged.deletedPlaylistIds = deletedPlaylistIds

        // Merge episode states (most recent state wins)
        var statesByGUID = Dictionary(uniqueKeysWithValues: newer.episodeStates.map { ($0.guid, $0) })
        for state in older.episodeStates {
            if statesByGUID[state.guid] == nil {
                statesByGUID[state.guid] = state
            }
            // Could add more sophisticated merging based on individual state timestamps
        }
        merged.episodeStates = Array(statesByGUID.values)

        return merged
    }

    /// Union newer/older items by id, then strip anything in the combined tombstone set.
    private func mergeById<T: SyncIdentifiable>(
        newer: [T],
        older: [T],
        localDeletedIds: [String],
        cloudDeletedIds: [String]
    ) -> (items: [T], deletedIds: [String]) {
        let deletedIds = Set(localDeletedIds).union(cloudDeletedIds)
        var byId = Dictionary(uniqueKeysWithValues: newer.map { ($0.id, $0) })
        for item in older where byId[item.id] == nil {
            byId[item.id] = item
        }
        for id in deletedIds {
            byId.removeValue(forKey: id)
        }
        return (Array(byId.values), Array(deletedIds))
    }
}

// MARK: - Sync Data Models

private protocol SyncIdentifiable {
    var id: String { get }
}

struct SyncData: Codable {
    var timestamp: Date
    var podcasts: [SyncPodcast]
    var folders: [SyncFolder]
    var playlists: [SyncPlaylist]
    var episodeStates: [SyncEpisodeState]
    var settings: SyncSettings?
    /// Folder IDs removed on any device — kept so merges don't resurrect them.
    var deletedFolderIds: [String]
    /// Playlist IDs removed on any device — kept so merges don't resurrect them.
    var deletedPlaylistIds: [String]

    init(
        timestamp: Date,
        podcasts: [SyncPodcast] = [],
        folders: [SyncFolder] = [],
        playlists: [SyncPlaylist] = [],
        episodeStates: [SyncEpisodeState] = [],
        settings: SyncSettings? = nil,
        deletedFolderIds: [String] = [],
        deletedPlaylistIds: [String] = []
    ) {
        self.timestamp = timestamp
        self.podcasts = podcasts
        self.folders = folders
        self.playlists = playlists
        self.episodeStates = episodeStates
        self.settings = settings
        self.deletedFolderIds = deletedFolderIds
        self.deletedPlaylistIds = deletedPlaylistIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        podcasts = try container.decodeIfPresent([SyncPodcast].self, forKey: .podcasts) ?? []
        folders = try container.decodeIfPresent([SyncFolder].self, forKey: .folders) ?? []
        playlists = try container.decodeIfPresent([SyncPlaylist].self, forKey: .playlists) ?? []
        episodeStates = try container.decodeIfPresent([SyncEpisodeState].self, forKey: .episodeStates) ?? []
        settings = try container.decodeIfPresent(SyncSettings.self, forKey: .settings)
        deletedFolderIds = try container.decodeIfPresent([String].self, forKey: .deletedFolderIds) ?? []
        deletedPlaylistIds = try container.decodeIfPresent([String].self, forKey: .deletedPlaylistIds) ?? []
    }
}

struct SyncPodcast: Codable {
    var feedURL: String
    var playbackSpeedOverride: Double?
}

struct SyncFolder: Codable, SyncIdentifiable {
    var id: String
    var name: String
    var colorHex: String?
    var sortOrder: Int
    var podcastFeedURLs: [String]
}

struct SyncPlaylist: Codable, SyncIdentifiable {
    var id: String
    var name: String
    var colorHex: String?
    var sortOrder: Int
    var episodeGUIDs: [String]
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
