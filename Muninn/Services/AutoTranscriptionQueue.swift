import Foundation
import SwiftData
import os

/// Manages a sequential queue for auto-transcribing downloaded episodes.
/// Only one episode is transcribed at a time to avoid overwhelming the system.
@Observable
final class AutoTranscriptionQueue {
    static let shared = AutoTranscriptionQueue()

    private let logger = Logger(subsystem: "com.muninn", category: "AutoTranscriptionQueue")

    private(set) var isProcessing = false
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
        guard let index = queue.firstIndex(where: { $0.guid == guid }) else { return nil }
        return (position: index + 1, total: queue.count)
    }

    func enqueue(episode: Episode, context: ModelContext) {
        queue.append(episode)
        modelContext = context
        logger.info("Enqueued episode for auto-transcription: \(episode.title)")
        processNextIfNeeded()
    }

    private func processNextIfNeeded() {
        guard !isProcessing, !queue.isEmpty, let context = modelContext else { return }

        isProcessing = true
        let episode = queue.removeFirst()

        Task {
            logger.info("Starting auto-transcription for: \(episode.title)")
            let started = await LocalTranscriptionService.shared.transcribe(episode: episode, context: context)

            await MainActor.run {
                if !started {
                    // Service was busy (manual transcription in progress) — re-insert at front to retry
                    self.queue.insert(episode, at: 0)
                    logger.info("Re-queued episode (service was busy): \(episode.title)")
                }
                self.isProcessing = false
                self.processNextIfNeeded()
            }
        }
    }
}
