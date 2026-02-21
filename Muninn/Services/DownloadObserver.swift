import Foundation
import SwiftData
import Combine
import os

/// Observes download notifications and updates SwiftData episodes
@Observable
final class DownloadObserver {
    static let shared = DownloadObserver()

    private let logger = AppLogger.download
    private var cancellables = Set<AnyCancellable>()
    private var modelContext: ModelContext?

    private init() {
        setupObservers()
    }

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    private func setupObservers() {
        NotificationCenter.default.publisher(for: .downloadCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleDownloadCompleted(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .downloadFailed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleDownloadFailed(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .episodePlaybackCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleEpisodeCompleted(notification)
            }
            .store(in: &cancellables)
    }

    private func handleDownloadCompleted(_ notification: Notification) {
        guard let context = modelContext,
              let userInfo = notification.userInfo,
              let guid = userInfo["guid"] as? String,
              let localPath = userInfo["localPath"] as? String else { return }

        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.guid == guid }
        )

        do {
            if let episode = try context.fetch(descriptor).first {
                episode.localFilePath = localPath
                episode.downloadProgress = nil
                try context.save()
                logger.info("Updated episode with download path: \(episode.title)")

                // Enforce storage limit and per-podcast limit after download
                DownloadCleanupService.shared.enforceStorageLimit(context: context)
                if let podcast = episode.podcast {
                    DownloadCleanupService.shared.enforcePerPodcastLimit(for: podcast, context: context)
                }
            }
        } catch {
            logger.error("Failed to update episode after download: \(error.localizedDescription)")
        }
    }

    private func handleDownloadFailed(_ notification: Notification) {
        guard let context = modelContext,
              let userInfo = notification.userInfo,
              let url = userInfo["url"] as? URL else { return }

        // Find episode by audio URL and clear download progress
        let urlString = url.absoluteString
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.audioURL == urlString }
        )

        do {
            if let episode = try context.fetch(descriptor).first {
                episode.downloadProgress = nil
                try context.save()
                logger.warning("Cleared download progress after failure for: \(episode.title)")
            }
        } catch {
            logger.error("Failed to update episode after download failure: \(error.localizedDescription)")
        }
    }

    private func handleEpisodeCompleted(_ notification: Notification) {
        guard let context = modelContext,
              let userInfo = notification.userInfo,
              let guid = userInfo["guid"] as? String else { return }

        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.guid == guid }
        )

        do {
            if let episode = try context.fetch(descriptor).first {
                DownloadCleanupService.shared.onEpisodeCompleted(episode, context: context)
            }
        } catch {
            logger.error("Failed to handle episode completion: \(error.localizedDescription)")
        }
    }
}
