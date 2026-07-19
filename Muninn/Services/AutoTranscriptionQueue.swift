import Foundation
import SwiftData
import os

/// Manages a sequential queue for auto-transcribing downloaded episodes.
/// Only one episode is transcribed at a time to avoid overwhelming the system.
@MainActor
@Observable
final class AutoTranscriptionQueue {
    static let shared = AutoTranscriptionQueue()

    private let logger = Logger(subsystem: "com.muninn", category: "AutoTranscriptionQueue")

    private struct QueuedItem {
        let episode: Episode
        let userInitiated: Bool
    }

    private(set) var isProcessing = false
    /// Observable mirror of queued episode GUIDs (for SwiftUI updates).
    private(set) var queuedGUIDs: [String] = []
    private var queue: [QueuedItem] = []
    private var modelContext: ModelContext?

    /// GUIDs of episodes the user explicitly asked to transcribe once their download finishes.
    /// This bypasses the global `autoTranscribeEnabled` setting.
    private var pendingTranscribeOnDownload: Set<String> = []

    private init() {}

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    /// Marks an episode to be transcribed as soon as its download completes,
    /// regardless of the global auto-transcribe setting.
    func requestTranscribeAfterDownload(guid: String) {
        pendingTranscribeOnDownload.insert(guid)
        logger.info("Marked episode for transcription after download: \(guid)")
    }

    /// Returns `true` and removes the entry if this GUID had a pending transcribe request.
    func consumeTranscribeRequest(guid: String) -> Bool {
        pendingTranscribeOnDownload.remove(guid) != nil
    }

    /// Returns the 1-based position and total waiting count for the given episode GUID,
    /// or `nil` if the episode is not queued. The currently-transcribing episode has
    /// already been removed, so position 1 means "up next."
    func queuePosition(for guid: String) -> (position: Int, total: Int)? {
        guard let index = queuedGUIDs.firstIndex(of: guid) else { return nil }
        return (position: index + 1, total: queuedGUIDs.count)
    }

    func enqueueIfEnabled(episode: Episode, context: ModelContext) {
        let settings = AppSettings.getOrCreate(context: context)
        guard settings.autoTranscribeEnabled else { return }
        enqueue(episode: episode, context: context, userInitiated: false)
    }

    /// Enqueues transcription regardless of the auto-transcribe setting (user-initiated).
    func enqueue(episode: Episode, context: ModelContext) {
        enqueue(episode: episode, context: context, userInitiated: true)
    }

    /// Drops auto-queued / persisted transcription work when the setting is turned off.
    /// User-initiated jobs stay queued. Does not cancel in-flight transcription.
    func applyAutoTranscribeSetting(enabled: Bool, context: ModelContext) {
        modelContext = context
        guard !enabled else { return }
        drainAutoWork(context: context, reason: "auto-transcribe disabled")
        EpisodeProcessingBackgroundManager.shared.notifyWorkStateChanged()
    }

    func removeFromQueue(guid: String) {
        let before = queue.count
        queue.removeAll { $0.episode.guid == guid }
        if queue.count != before {
            syncQueuedGUIDs()
            logger.info("Removed episode from transcription queue: \(guid)")
        }
        pendingTranscribeOnDownload.remove(guid)
        PendingWorkStore.removeTranscription(guid: guid)
        EpisodeProcessingBackgroundManager.shared.notifyWorkStateChanged()
    }

    /// Re-enqueues interrupted or persisted work after relaunch or BGProcessingTask.
    func resumePersistedWork(context: ModelContext) {
        modelContext = context

        let settings = AppSettings.getOrCreate(context: context)
        if !settings.autoTranscribeEnabled {
            drainAutoWork(context: context, reason: "auto-transcribe disabled — skip resume")
            processNextIfNeeded()
            EpisodeProcessingBackgroundManager.shared.notifyWorkStateChanged()
            return
        }

        if let episodes = try? context.fetch(FetchDescriptor<Episode>()) {
            for episode in episodes where episode.transcriptionProgress != nil && !Self.hasTranscript(episode) {
                enqueue(episode: episode, context: context, userInitiated: false)
            }
        }

        for guid in PendingWorkStore.transcriptionGUIDs {
            guard let episode = Self.fetchEpisode(guid: guid, context: context) else {
                PendingWorkStore.removeTranscription(guid: guid)
                continue
            }
            enqueue(episode: episode, context: context, userInitiated: false)
        }
    }

    private func enqueue(episode: Episode, context: ModelContext, userInitiated: Bool) {
        if Self.hasTranscript(episode) {
            logger.info("Skipping transcription — transcript exists: \(episode.title)")
            PendingWorkStore.removeTranscription(guid: episode.guid)
            return
        }
        guard !queue.contains(where: { $0.episode.guid == episode.guid }) else {
            logger.info("Skipping transcription — already queued: \(episode.title)")
            return
        }

        queue.append(QueuedItem(episode: episode, userInitiated: userInitiated))
        syncQueuedGUIDs()
        modelContext = context
        PendingWorkStore.addTranscription(guid: episode.guid)
        logger.info(
            "Enqueued episode for transcription (\(userInitiated ? "user" : "auto")): \(episode.title)"
        )
        processNextIfNeeded()
        EpisodeProcessingBackgroundManager.shared.notifyWorkStateChanged()
    }

    private func drainAutoWork(context: ModelContext, reason: String) {
        let removed = queue.filter { !$0.userInitiated }
        queue.removeAll { !$0.userInitiated }
        syncQueuedGUIDs()

        let keepPending = Set(queue.map(\.episode.guid))
        for guid in PendingWorkStore.transcriptionGUIDs where !keepPending.contains(guid) {
            if LocalTranscriptionService.shared.isActivelyTranscribing(episodeGUID: guid) { continue }
            PendingWorkStore.removeTranscription(guid: guid)
        }

        // Clear stalled auto progress so episodes don't look mid-transcribe forever.
        if let episodes = try? context.fetch(FetchDescriptor<Episode>()) {
            var changed = false
            for episode in episodes where episode.transcriptionProgress != nil {
                if LocalTranscriptionService.shared.isActivelyTranscribing(episodeGUID: episode.guid) {
                    continue
                }
                if keepPending.contains(episode.guid) { continue }
                episode.transcriptionProgress = nil
                changed = true
            }
            if changed { try? context.save() }
        }

        if !removed.isEmpty {
            logger.info("Drained \(removed.count) auto transcription queue item(s) — \(reason)")
        }
    }

    private func syncQueuedGUIDs() {
        queuedGUIDs = queue.map(\.episode.guid)
    }

    private func processNextIfNeeded() {
        guard let context = modelContext else { return }

        let settings = AppSettings.getOrCreate(context: context)
        if !settings.autoTranscribeEnabled {
            drainAutoWork(context: context, reason: "auto-transcribe disabled")
        }

        guard !isProcessing, !queue.isEmpty else { return }
        guard !EpisodeProcessingBackgroundManager.shared.isAutoProcessingSuspended else {
            logger.info("Skipping next transcription — auto processing suspended")
            return
        }

        isProcessing = true
        let item = queue.removeFirst()
        syncQueuedGUIDs()
        let episode = item.episode

        Task {
            logger.info(
                "Starting \(item.userInitiated ? "user" : "auto") transcription for: \(episode.title)"
            )
            let success = await LocalTranscriptionService.shared.transcribe(episode: episode, context: context)

            if !success, LocalTranscriptionService.shared.isTranscribing {
                // Another transcription is in progress — retry this episode later.
                self.queue.insert(item, at: 0)
                self.syncQueuedGUIDs()
                logger.info("Re-queued episode (transcription service busy): \(episode.title)")
            } else if !success {
                // Cancellation / background interrupt keeps PendingWorkStore for resume.
                // Permanent failures clear it inside LocalTranscriptionService.
                if PendingWorkStore.transcriptionGUIDs.contains(episode.guid) {
                    logger.warning(
                        "Transcription interrupted — keeping pending for retry: \(episode.title)"
                    )
                } else {
                    logger.warning("Transcription failed, not retrying: \(episode.title)")
                }
            } else {
                PendingWorkStore.removeTranscription(guid: episode.guid)
            }

            self.isProcessing = false
            self.processNextIfNeeded()
            EpisodeProcessingBackgroundManager.shared.notifyWorkStateChanged()
        }
    }

    private static func hasTranscript(_ episode: Episode) -> Bool {
        guard episode.localTranscriptPath != nil,
              let url = episode.localTranscriptURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        return true
    }

    private static func fetchEpisode(guid: String, context: ModelContext) -> Episode? {
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        return try? context.fetch(descriptor).first
    }
}
