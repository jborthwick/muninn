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
            QueueManager.shared.addToQueue(episode)
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
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

        // Share (only if podcast can be shared)
        if let podcast = episode.podcast, podcast.canShare {
            ShareLink(item: podcast.shareURL) {
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
            episode.isPlayed.toggle()
        } label: {
            Label(
                episode.isPlayed ? "Mark Unplayed" : "Mark Played",
                systemImage: episode.isPlayed ? "circle" : "checkmark.circle"
            )
        }
    }
}
