import SwiftUI

struct EpisodeContextMenu: View {
    let episode: Episode
    var onPlay: (() -> Void)?

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
                DownloadManager.shared.download(episode)
            }
        } label: {
            Label(
                episode.isStarred ? "Unstar" : "Star",
                systemImage: episode.isStarred ? "star.slash" : "star"
            )
        }

        // Share
        if let shareURL = episode.podcast?.shareURL {
            ShareLink(item: shareURL) {
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
                DownloadManager.shared.download(episode)
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
