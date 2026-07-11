import Foundation
import SwiftData
import os

/// Manages user-created episode playlists
@Observable
final class PlaylistManager {
    static let shared = PlaylistManager()

    private let logger = AppLogger.data
    private var modelContext: ModelContext?

    private init() {}

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Playlist CRUD

    @discardableResult
    func createPlaylist(name: String, colorHex: String? = "007AFF") -> Playlist? {
        guard let context = modelContext else { return nil }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return nil }

        let playlist = Playlist(name: trimmedName, colorHex: colorHex)
        playlist.sortOrder = nextPlaylistSortOrder()
        context.insert(playlist)

        do {
            try context.save()
            logger.info("Created playlist: \(trimmedName)")
            return playlist
        } catch {
            logger.error("Failed to create playlist: \(error.localizedDescription)")
            return nil
        }
    }

    func deletePlaylist(_ playlist: Playlist) {
        guard let context = modelContext else { return }
        context.delete(playlist)

        do {
            try context.save()
            logger.info("Deleted playlist: \(playlist.name)")
        } catch {
            logger.error("Failed to delete playlist: \(error.localizedDescription)")
        }
    }

    func movePlaylists(_ playlists: [Playlist], from source: IndexSet, to destination: Int) {
        guard let context = modelContext else { return }

        var ordered = playlists
        ordered.move(fromOffsets: source, toOffset: destination)

        for (index, playlist) in ordered.enumerated() where playlist.sortOrder != index {
            playlist.sortOrder = index
        }

        do {
            try context.save()
        } catch {
            logger.error("Failed to reorder playlists: \(error.localizedDescription)")
        }
    }

    // MARK: - Item Operations

    func addEpisode(_ episode: Episode, to playlist: Playlist) {
        guard let context = modelContext else { return }
        guard !isInPlaylist(episode, playlist: playlist) else { return }

        let nextOrder = nextItemSortOrder(in: playlist)
        let item = PlaylistItem(episode: episode, sortOrder: nextOrder)
        item.playlist = playlist
        playlist.items.append(item)
        context.insert(item)

        do {
            try context.save()
            logger.info("Added episode to playlist \(playlist.name): \(episode.title)")
        } catch {
            logger.error("Failed to add episode to playlist: \(error.localizedDescription)")
        }
    }

    func addEpisodes(_ episodes: [Episode], to playlist: Playlist) {
        for episode in episodes {
            addEpisode(episode, to: playlist)
        }
    }

    func removeEpisode(_ episode: Episode, from playlist: Playlist) {
        guard let context = modelContext else { return }

        for item in playlist.items where item.episode?.guid == episode.guid {
            context.delete(item)
        }

        do {
            try context.save()
            logger.info("Removed episode from playlist \(playlist.name): \(episode.title)")
        } catch {
            logger.error("Failed to remove episode from playlist: \(error.localizedDescription)")
        }
    }

    func removeItem(_ item: PlaylistItem) {
        guard let context = modelContext else { return }
        context.delete(item)

        do {
            try context.save()
        } catch {
            logger.error("Failed to remove playlist item: \(error.localizedDescription)")
        }
    }

    func clearPlaylist(_ playlist: Playlist) {
        guard let context = modelContext else { return }

        for item in playlist.items {
            context.delete(item)
        }

        do {
            try context.save()
            logger.info("Cleared playlist: \(playlist.name)")
        } catch {
            logger.error("Failed to clear playlist: \(error.localizedDescription)")
        }
    }

    func isInPlaylist(_ episode: Episode, playlist: Playlist) -> Bool {
        playlist.items.contains { $0.episode?.guid == episode.guid }
    }

    func moveItems(_ items: [PlaylistItem], from source: IndexSet, to destination: Int) {
        guard let context = modelContext else { return }

        var ordered = items
        ordered.move(fromOffsets: source, toOffset: destination)

        for (index, item) in ordered.enumerated() where item.sortOrder != index {
            item.sortOrder = index
        }

        do {
            try context.save()
        } catch {
            logger.error("Failed to reorder playlist items: \(error.localizedDescription)")
        }
    }

    // MARK: - Playback

    /// Replaces Up Next with the playlist and starts the first episode.
    func play(_ playlist: Playlist) {
        let episodes = sortedEpisodes(in: playlist)
        guard !episodes.isEmpty else { return }

        QueueManager.shared.clearQueue()
        for episode in episodes {
            QueueManager.shared.addToQueue(episode)
        }

        if let first = episodes.first {
            Task { @MainActor in
                AudioPlayerManager.shared.play(first)
            }
        }
    }

    /// Appends playlist episodes to Up Next without clearing existing items.
    func addToQueue(_ playlist: Playlist) {
        for episode in sortedEpisodes(in: playlist) {
            QueueManager.shared.addToQueue(episode)
        }
    }

    // MARK: - Helpers

    func sortedItems(in playlist: Playlist) -> [PlaylistItem] {
        playlist.items.sorted { $0.sortOrder < $1.sortOrder }
    }

    func sortedEpisodes(in playlist: Playlist) -> [Episode] {
        sortedItems(in: playlist).compactMap(\.episode)
    }

    private func nextPlaylistSortOrder() -> Int {
        guard let context = modelContext else { return 0 }

        let descriptor = FetchDescriptor<Playlist>()
        let playlists = (try? context.fetch(descriptor)) ?? []
        return (playlists.map(\.sortOrder).max() ?? -1) + 1
    }

    private func nextItemSortOrder(in playlist: Playlist) -> Int {
        (playlist.items.map(\.sortOrder).max() ?? -1) + 1
    }
}
