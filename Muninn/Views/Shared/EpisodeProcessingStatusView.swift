import SwiftUI

/// Compact processing indicator for episode list rows (transcription / chapter queues).
struct EpisodeProcessingStatusView: View {
    @Bindable var episode: Episode

    init(episode: Episode) {
        self.episode = episode
    }

    private var transcriptionQueue = AutoTranscriptionQueue.shared
    private var chapterQueue = AutoChapterQueue.shared
    private var transcriptionService = LocalTranscriptionService.shared
    private var chapterService = ChapterService.shared

    private var status: Status? {
        // Touch observable queue state so list rows refresh when queues change.
        _ = transcriptionQueue.queuedGUIDs
        _ = chapterQueue.queuedGUIDs
        _ = transcriptionQueue.isProcessing
        _ = chapterQueue.isProcessing

        if transcriptionService.isActivelyTranscribing(episodeGUID: episode.guid) {
            let progress = episode.transcriptionProgress ?? transcriptionService.progress
            return .transcribing(progress)
        }
        if transcriptionService.isStalled(episode: episode),
           let progress = episode.transcriptionProgress {
            return .stalled(progress)
        }
        if chapterService.generatingEpisodeGUID == episode.guid {
            return .generatingChapters
        }
        if let position = transcriptionQueue.queuePosition(for: episode.guid) {
            return .transcriptionQueued(position: position.position, total: position.total)
        }
        if let position = chapterQueue.queuePosition(for: episode.guid) {
            return .chaptersQueued(position: position.position, total: position.total)
        }
        return nil
    }

    var body: some View {
        if let status {
            HStack(spacing: 5) {
                if status.showsSpinner {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: status.icon)
                        .font(.caption2)
                }
                Text(status.label)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(status.color)
        }
    }

    private enum Status {
        case transcribing(Double)
        case stalled(Double)
        case transcriptionQueued(position: Int, total: Int)
        case generatingChapters
        case chaptersQueued(position: Int, total: Int)

        var showsSpinner: Bool {
            switch self {
            case .transcribing, .generatingChapters: return true
            default: return false
            }
        }

        var icon: String {
            switch self {
            case .stalled: return "exclamationmark.triangle"
            case .transcriptionQueued, .chaptersQueued: return "clock"
            default: return "waveform"
            }
        }

        var label: String {
            switch self {
            case .transcribing(let progress):
                if progress > 0 {
                    return "Transcribing · \(Int(progress * 100))%"
                }
                return "Transcribing…"
            case .stalled(let progress):
                return "Interrupted · \(Int(progress * 100))%"
            case .transcriptionQueued(let position, let total):
                return "Transcription queue · \(position) of \(total)"
            case .generatingChapters:
                return "Generating chapters…"
            case .chaptersQueued(let position, let total):
                return "Chapter queue · \(position) of \(total)"
            }
        }

        var color: Color {
            switch self {
            case .transcribing: return .purple
            case .stalled: return .orange
            case .generatingChapters: return .orange
            case .transcriptionQueued, .chaptersQueued: return .secondary
            }
        }
    }
}
