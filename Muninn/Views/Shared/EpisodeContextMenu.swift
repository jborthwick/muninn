import SwiftUI
import SwiftData

struct EpisodeContextMenu: View {
    @Environment(\.modelContext) private var modelContext
    let episode: Episode
    var onPlay: (() -> Void)?
    var onDownloadNeedsConfirmation: (() -> Void)?

    var body: some View {
        // Play actions
        Button {
            if let onPlay {
                onPlay()
            } else {
                AudioPlayerManager.shared.play(episode)
            }
        } label: {
            Label("Play", systemImage: "play")
        }

        Button {
            QueueManager.shared.playNext(episode)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            if QueueManager.shared.isInQueue(episode) {
                QueueManager.shared.removeFromQueue(episode)
            } else {
                QueueManager.shared.addToQueue(episode)
            }
        } label: {
            if QueueManager.shared.isInQueue(episode) {
                Label("Remove from Queue", systemImage: "text.badge.checkmark")
            } else {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
        }

        Divider()

        // Star
        Button {
            episode.isStarred.toggle()
            if episode.isStarred && episode.localFilePath == nil {
                let result = DownloadManager.shared.checkDownloadAllowed(episode, isAutoDownload: true, context: modelContext)
                switch result {
                case .started:
                    DownloadManager.shared.download(episode)
                case .needsConfirmation:
                    onDownloadNeedsConfirmation?()
                case .blocked, .alreadyDownloaded, .alreadyDownloading:
                    break
                }
            }
        } label: {
            Label(
                episode.isStarred ? "Unstar" : "Star",
                systemImage: episode.isStarred ? "star.slash" : "star"
            )
        }

        // Share (only if episode can be shared)
        if episode.canShare {
            ShareLink(item: episode.shareURL) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }

        Divider()

        // Download actions
        if episode.localFilePath != nil {
            Button(role: .destructive) {
                DownloadManager.shared.deleteDownload(episode)
            } label: {
                Label("Delete Download", systemImage: "trash")
            }
        } else if episode.downloadProgress != nil {
            Button {
                DownloadManager.shared.cancelDownload(episode)
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        } else {
            Button {
                let result = DownloadManager.shared.checkDownloadAllowed(episode, isAutoDownload: false, context: modelContext)
                switch result {
                case .started:
                    DownloadManager.shared.download(episode)
                case .needsConfirmation:
                    onDownloadNeedsConfirmation?()
                case .blocked, .alreadyDownloaded, .alreadyDownloading:
                    break
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }

        Divider()

        // Mark played/unplayed
        Button {
            if !episode.isPlayed &&
               AudioPlayerManager.shared.currentEpisode?.guid == episode.guid {
                AudioPlayerManager.shared.markPlayedAndAdvance()
            } else {
                episode.isPlayed.toggle()
            }
        } label: {
            Label(
                episode.isPlayed ? "Mark Unplayed" : "Mark Played",
                systemImage: episode.isPlayed ? "circle" : "checkmark.circle"
            )
        }
    }
}
