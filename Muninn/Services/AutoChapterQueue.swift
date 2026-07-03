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
            logger.info("Skipping auto chapters — already generated for: \(episode.title)")
            return
        }
        guard !queue.contains(where: { $0.guid == episode.guid }) else { return }

        queue.append(episode)
        syncQueuedGUIDs()
        modelContext = context
        logger.info("Enqueued episode for auto chapter generation: \(episode.title)")
        processNextIfNeeded()
    }

    private func syncQueuedGUIDs() {
        queuedGUIDs = queue.map(\.guid)
    }

    private func processNextIfNeeded() {
        guard !isProcessing, !queue.isEmpty, let context = modelContext else { return }

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
            let success = await ChapterService.shared.generate(episode: episode, context: context)
            if success {
                logger.info("Auto chapter generation succeeded: \(episode.title)")
            } else {
                logger.warning("Auto chapter generation failed: \(episode.title)")
            }
            isProcessing = false
            processNextIfNeeded()
        }
    }
}
