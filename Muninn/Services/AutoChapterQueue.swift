import Foundation
import SwiftData
import os

/// Sequential queue for auto-generating chapters and summaries after transcription.
@MainActor
@Observable
final class AutoChapterQueue {
    static let shared = AutoChapterQueue()

    private let logger = Logger(subsystem: "com.muninn", category: "AutoChapterQueue")

    private(set) var isProcessing = false
    /// Observable mirror of queued episode GUIDs (for SwiftUI updates).
    private(set) var queuedGUIDs: [String] = []
    private var queue: [Episode] = []
    private var modelContext: ModelContext?

    private init() {}

    func setModelContext(_ context: ModelContext) {
        modelContext = context
    }

    /// Returns the 1-based position and total waiting count for the given episode GUID,
    /// or `nil` if the episode is not queued.
    func queuePosition(for guid: String) -> (position: Int, total: Int)? {
        guard let index = queuedGUIDs.firstIndex(of: guid) else { return nil }
        return (position: index + 1, total: queuedGUIDs.count)
    }

    func enqueueIfEnabled(episode: Episode, context: ModelContext) {
        let settings = AppSettings.getOrCreate(context: context)
        guard settings.autoGenerateChaptersEnabled else { return }
        guard episode.localChaptersPath == nil else {
            PendingWorkStore.removeChapter(guid: episode.guid)
            logger.info("Skipping auto chapters — already generated for: \(episode.title)")
            return
        }
        enqueue(episode: episode, context: context)
    }

    /// Enqueues chapter generation regardless of the auto-generate setting (user-initiated).
    /// Episodes that already have chapters may be enqueued for regeneration.
    func enqueue(episode: Episode, context: ModelContext) {
        guard !queue.contains(where: { $0.guid == episode.guid }) else { return }
        guard !ChapterService.shared.isGenerating(for: episode.guid) else { return }

        queue.append(episode)
        syncQueuedGUIDs()
        modelContext = context
        PendingWorkStore.addChapter(guid: episode.guid)
        logger.info("Enqueued episode for chapter generation: \(episode.title)")
        processNextIfNeeded()
        EpisodeProcessingBackgroundManager.shared.notifyWorkStateChanged()
    }

    func removeFromQueue(guid: String) {
        let before = queue.count
        queue.removeAll { $0.guid == guid }
        if queue.count != before {
            syncQueuedGUIDs()
            logger.info("Removed episode from chapter queue: \(guid)")
        }
        PendingWorkStore.removeChapter(guid: guid)
        EpisodeProcessingBackgroundManager.shared.notifyWorkStateChanged()
    }

    /// Re-enqueues persisted chapter work after relaunch or BGProcessingTask.
    func resumePersistedWork(context: ModelContext) {
        modelContext = context

        for guid in PendingWorkStore.chapterGUIDs {
            guard let episode = Self.fetchEpisode(guid: guid, context: context) else {
                PendingWorkStore.removeChapter(guid: guid)
                continue
            }
            guard episode.localChaptersPath == nil else {
                PendingWorkStore.removeChapter(guid: guid)
                continue
            }
            guard !queue.contains(where: { $0.guid == guid }) else { continue }
            queue.append(episode)
            syncQueuedGUIDs()
        }
        processNextIfNeeded()
        EpisodeProcessingBackgroundManager.shared.notifyWorkStateChanged()
    }

    private func syncQueuedGUIDs() {
        queuedGUIDs = queue.map(\.guid)
    }

    private func processNextIfNeeded() {
        guard !isProcessing, !queue.isEmpty, let context = modelContext else { return }
        guard !EpisodeProcessingBackgroundManager.shared.isAutoProcessingSuspended else {
            logger.info("Skipping next chapter generation — auto processing suspended")
            return
        }

        if ChapterService.shared.isGenerating {
            Task {
                try? await Task.sleep(for: .seconds(3))
                processNextIfNeeded()
            }
            return
        }

        isProcessing = true
        let episode = queue.removeFirst()
        syncQueuedGUIDs()

        Task {
            logger.info("Starting auto chapter generation for: \(episode.title)")
            let outcome = await ChapterService.shared.generate(episode: episode, context: context)
            switch outcome {
            case .succeeded:
                logger.info("Auto chapter generation succeeded: \(episode.title)")
            case .failedPermanent:
                logger.warning("Auto chapter generation failed permanently: \(episode.title)")
            case .failedRetryable:
                // Keep PendingWorkStore entry, but do not re-queue here. Immediate
                // re-enqueue can cancel/restart-loop if generation is interrupted
                // again (e.g. background task expiry). become-active and
                // BGProcessingTask call resumePersistedWork instead.
                logger.warning(
                    "Auto chapter generation interrupted — keeping pending for retry: \(episode.title)"
                )
            }
            isProcessing = false
            processNextIfNeeded()
            EpisodeProcessingBackgroundManager.shared.notifyWorkStateChanged()
        }
    }

    private static func fetchEpisode(guid: String, context: ModelContext) -> Episode? {
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        return try? context.fetch(descriptor).first
    }
}
