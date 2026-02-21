import Foundation
import SwiftData
import os

/// Manages the playback queue
@Observable
final class QueueManager {
    static let shared = QueueManager()

    private let logger = AppLogger.data
    private var modelContext: ModelContext?

    private init() {}

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Queue Operations

    /// Adds an episode to the end of the queue
    func addToQueue(_ episode: Episode) {
        guard let context = modelContext else { return }

        // Check if already in queue
        if isInQueue(episode) { return }

        // Get next sort order
        let nextOrder = getNextSortOrder()

        let queueItem = QueueItem(episode: episode, sortOrder: nextOrder)
        context.insert(queueItem)

        // Auto-download when adding to queue
        if episode.localFilePath == nil {
            DownloadManager.shared.download(episode)
        }

        do {
            try context.save()
            logger.info("Added episode to queue: \(episode.title)")
        } catch {
            logger.error("Failed to save queue addition: \(error.localizedDescription)")
        }
    }

    /// Adds an episode to play next (top of queue)
    func playNext(_ episode: Episode) {
        guard let context = modelContext else { return }

        // Remove if already in queue
        removeFromQueue(episode)

        // Shift all existing items down
        let items = fetchQueueItems()
        for item in items {
            item.sortOrder += 1
        }

        // Add at top
        let queueItem = QueueItem(episode: episode, sortOrder: 0)
        context.insert(queueItem)

        // Auto-download when adding to queue
        if episode.localFilePath == nil {
            DownloadManager.shared.download(episode)
        }

        do {
            try context.save()
            logger.info("Added episode to play next: \(episode.title)")
        } catch {
            logger.error("Failed to save play next: \(error.localizedDescription)")
        }
    }

    /// Removes an episode from the queue
    func removeFromQueue(_ episode: Episode) {
        guard let context = modelContext else { return }

        let descriptor = FetchDescriptor<QueueItem>()
        let items: [QueueItem]
        do {
            items = try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch queue items: \(error.localizedDescription)")
            return
        }

        for item in items {
            if item.episode?.guid == episode.guid {
                context.delete(item)
            }
        }

        do {
            try context.save()
            logger.info("Removed episode from queue: \(episode.title)")
        } catch {
            logger.error("Failed to save queue removal: \(error.localizedDescription)")
        }
    }

    /// Checks if an episode is in the queue
    func isInQueue(_ episode: Episode) -> Bool {
        let items = fetchQueueItems()
        return items.contains { $0.episode?.guid == episode.guid }
    }

    /// Returns the next episode in queue (and removes it)
    func popNextEpisode() -> Episode? {
        guard let context = modelContext else { return nil }

        let items = fetchQueueItems().sorted { $0.sortOrder < $1.sortOrder }
        guard let firstItem = items.first, let episode = firstItem.episode else {
            return nil
        }

        context.delete(firstItem)
        do {
            try context.save()
            logger.info("Popped episode from queue: \(episode.title)")
        } catch {
            logger.error("Failed to save queue pop: \(error.localizedDescription)")
        }

        return episode
    }

    /// Peeks at the next episode without removing it
    func peekNextEpisode() -> Episode? {
        let items = fetchQueueItems().sorted { $0.sortOrder < $1.sortOrder }
        return items.first?.episode
    }

    /// Moves an item in the queue
    func moveItem(from source: IndexSet, to destination: Int) {
        guard let context = modelContext else { return }

        var items = fetchQueueItems().sorted { $0.sortOrder < $1.sortOrder }
        items.move(fromOffsets: source, toOffset: destination)

        // Update sort orders
        for (index, item) in items.enumerated() {
            item.sortOrder = index
        }

        do {
            try context.save()
        } catch {
            logger.error("Failed to save queue reorder: \(error.localizedDescription)")
        }
    }

    /// Clears the entire queue
    func clearQueue() {
        guard let context = modelContext else { return }

        let items = fetchQueueItems()
        for item in items {
            context.delete(item)
        }

        do {
            try context.save()
            logger.info("Cleared queue (\(items.count) items)")
        } catch {
            logger.error("Failed to save queue clear: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func fetchQueueItems() -> [QueueItem] {
        guard let context = modelContext else { return [] }

        let descriptor = FetchDescriptor<QueueItem>()
        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch queue items: \(error.localizedDescription)")
            return []
        }
    }

    private func getNextSortOrder() -> Int {
        let items = fetchQueueItems()
        let maxOrder = items.map { $0.sortOrder }.max() ?? -1
        return maxOrder + 1
    }
}
