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

    private(set) var isProcessing = false
    /// Observable mirror of queued episode GUIDs (for SwiftUI updates).
    private(set) var queuedGUIDs: [String] = []
    private var queue: [Episode] = []
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

    func enqueue(episode: Episode, context: ModelContext) {
        if episode.localTranscriptPath != nil,
           let url = episode.localTranscriptURL,
           FileManager.default.fileExists(atPath: url.path) {
            logger.info("Skipping auto-transcription — transcript exists: \(episode.title)")
            return
        }
        guard !queue.contains(where: { $0.guid == episode.guid }) else {
            logger.info("Skipping auto-transcription — already queued: \(episode.title)")
            return
        }

        queue.append(episode)
        syncQueuedGUIDs()
        modelContext = context
        logger.info("Enqueued episode for auto-transcription: \(episode.title)")
        processNextIfNeeded()
    }

    func removeFromQueue(guid: String) {
        let before = queue.count
        queue.removeAll { $0.guid == guid }
        if queue.count != before {
            syncQueuedGUIDs()
            logger.info("Removed episode from transcription queue: \(guid)")
        }
        pendingTranscribeOnDownload.remove(guid)
    }

    private func syncQueuedGUIDs() {
        queuedGUIDs = queue.map(\.guid)
    }

    private func processNextIfNeeded() {
        guard !isProcessing, !queue.isEmpty, let context = modelContext else { return }

        isProcessing = true
        let episode = queue.removeFirst()
        syncQueuedGUIDs()

        Task {
            logger.info("Starting auto-transcription for: \(episode.title)")
            let success = await LocalTranscriptionService.shared.transcribe(episode: episode, context: context)

            if !success, LocalTranscriptionService.shared.isTranscribing {
                // Another transcription is in progress — retry this episode later.
                self.queue.insert(episode, at: 0)
                self.syncQueuedGUIDs()
                logger.info("Re-queued episode (transcription service busy): \(episode.title)")
            } else if !success {
                logger.warning("Auto-transcription failed, not retrying: \(episode.title)")
            }

            self.isProcessing = false
            self.processNextIfNeeded()
        }
    }
}
