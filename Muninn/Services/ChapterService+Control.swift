import Foundation
import SwiftData

extension ChapterService {
    /// User-facing cancel: dequeue and stop in-flight generation for this episode.
    func cancelGeneration(for episode: Episode, context: ModelContext) {
        AutoChapterQueue.shared.removeFromQueue(guid: episode.guid)
        if isGenerating(for: episode.guid) {
            cancelActiveGeneration()
        }
        try? context.save()
    }

    /// User tapped Generate / Regenerate Chapters.
    func userInitiatedGenerate(episode: Episode, context: ModelContext) async {
        AutoChapterQueue.shared.removeFromQueue(guid: episode.guid)
        if isGenerating(for: episode.guid) {
            return
        }
        if isGenerating {
            AutoChapterQueue.shared.enqueue(episode: episode, context: context)
            return
        }
        _ = await generate(episode: episode, context: context)
    }

    /// Whether this episode can attempt chapter generation (show notes or transcript).
    static func canGenerate(for episode: Episode) -> Bool {
        if let description = episode.episodeDescription, !description.isEmpty {
            return true
        }
        if episode.localTranscriptPath != nil { return true }
        if episode.transcriptURL != nil { return true }
        return false
    }
}
