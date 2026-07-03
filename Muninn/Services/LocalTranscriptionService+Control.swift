import Foundation
import SwiftData

extension LocalTranscriptionService {
    func isActivelyTranscribing(episodeGUID: String) -> Bool {
        isTranscribing && transcribingEpisodeGUID == episodeGUID
    }

    func isStalled(episode: Episode) -> Bool {
        episode.transcriptionProgress != nil && !isActivelyTranscribing(episodeGUID: episode.guid)
    }

    func clearTranscriptionState(for episode: Episode, context: ModelContext) {
        episode.transcriptionProgress = nil
        try? context.save()
    }

    func cancelTranscription(for episode: Episode, context: ModelContext) async {
        AutoTranscriptionQueue.shared.removeFromQueue(guid: episode.guid)

        if isActivelyTranscribing(episodeGUID: episode.guid) {
            await performCancellation()
        }
        clearTranscriptionState(for: episode, context: context)
    }

    func retryTranscription(episode: Episode, context: ModelContext) async {
        AutoTranscriptionQueue.shared.removeFromQueue(guid: episode.guid)
        clearTranscriptionState(for: episode, context: context)
        await transcribe(episode: episode, context: context)
    }

    /// Clears persisted progress left behind when transcription was interrupted.
    static func cleanupOrphanedProgress(context: ModelContext) {
        let service = shared
        let descriptor = FetchDescriptor<Episode>()
        guard let episodes = try? context.fetch(descriptor) else { return }

        var changed = false
        for episode in episodes where episode.transcriptionProgress != nil {
            guard !service.isActivelyTranscribing(episodeGUID: episode.guid) else { continue }
            episode.transcriptionProgress = nil
            changed = true
        }
        if changed { try? context.save() }
    }

    func registerCancellationHandler(_ handler: @escaping () async -> Void) {
        cancellationHandler = handler
    }

    func clearCancellationHandler() {
        cancellationHandler = nil
    }

    func performCancellation() async {
        await cancellationHandler?()
        cancellationHandler = nil
    }
}
