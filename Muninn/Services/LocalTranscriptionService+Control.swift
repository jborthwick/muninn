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
        if #available(iOS 26, *) {
            EpisodeContinuedProcessing.shared.cancelPipeline(for: episode.guid)
        }

        if isActivelyTranscribing(episodeGUID: episode.guid) {
            await performCancellation()
        }
        clearTranscriptionState(for: episode, context: context)
    }

    func retryTranscription(episode: Episode, context: ModelContext) async {
        AutoTranscriptionQueue.shared.removeFromQueue(guid: episode.guid)
        clearTranscriptionState(for: episode, context: context)
        if #available(iOS 26, *) {
            EpisodeContinuedProcessing.shared.beginTranscribe(episode: episode, context: context)
            return
        }
        await transcribe(episode: episode, context: context)
    }

    /// User tapped Transcribe — starts continued processing on iOS 26 when available.
    func userInitiatedTranscribe(episode: Episode, context: ModelContext) async {
        if episode.localFilePath == nil {
            AutoTranscriptionQueue.shared.requestTranscribeAfterDownload(guid: episode.guid)
            let result = DownloadManager.shared.checkDownloadAllowed(episode, isAutoDownload: false, context: context)
            switch result {
            case .started:
                if #available(iOS 26, *) {
                    EpisodeContinuedProcessing.shared.beginTranscribe(episode: episode, context: context)
                }
                DownloadManager.shared.download(episode)
            case .needsConfirmation, .blocked, .alreadyDownloaded, .alreadyDownloading:
                break
            }
            return
        }
        await retryTranscription(episode: episode, context: context)
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
