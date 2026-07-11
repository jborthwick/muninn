import SwiftUI
import SwiftData

struct EpisodeContextMenu: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Playlist.sortOrder) private var allPlaylists: [Playlist]
    let episode: Episode
    var onPlay: (() -> Void)?
    var onDownloadNeedsConfirmation: (() -> Void)?
    var onShowPlaylistPicker: (() -> Void)?

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

        if let onShowPlaylistPicker {
            Button {
                onShowPlaylistPicker()
            } label: {
                Label("Add to Playlist", systemImage: "music.note.list")
            }
        } else {
            playlistMenu
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
                DownloadManager.shared.deleteDownload(episode, context: modelContext)
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
                let result = DownloadManager.shared.downloadWithCheck(episode, isAutoDownload: false, context: modelContext)
                if case .needsConfirmation = result {
                    onDownloadNeedsConfirmation?()
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }

        Divider()

        // Transcription actions
        if LocalTranscriptionService.isSupported, episode.localFilePath != nil {
            if LocalTranscriptionService.shared.isActivelyTranscribing(episodeGUID: episode.guid) {
                Button(role: .destructive) {
                    Task {
                        await LocalTranscriptionService.shared.cancelTranscription(
                            for: episode,
                            context: modelContext
                        )
                    }
                } label: {
                    Label("Cancel Transcription", systemImage: "xmark.circle")
                }
            } else if LocalTranscriptionService.shared.isStalled(episode: episode) {
                Button {
                    Task {
                        await LocalTranscriptionService.shared.retryTranscription(
                            episode: episode,
                            context: modelContext
                        )
                    }
                } label: {
                    Label("Retry Transcription", systemImage: "arrow.clockwise")
                }
                Button {
                    LocalTranscriptionService.shared.clearTranscriptionState(
                        for: episode,
                        context: modelContext
                    )
                } label: {
                    Label("Dismiss Transcription", systemImage: "xmark")
                }
            } else if episode.localTranscriptPath == nil {
                if AutoTranscriptionQueue.shared.queuePosition(for: episode.guid) != nil {
                    Button {
                        AutoTranscriptionQueue.shared.removeFromQueue(guid: episode.guid)
                    } label: {
                        Label("Remove from Transcription Queue", systemImage: "list.number")
                    }
                } else {
                    Button {
                        Task {
                            await LocalTranscriptionService.shared.userInitiatedTranscribe(
                                episode: episode,
                                context: modelContext
                            )
                        }
                    } label: {
                        Label("Transcribe Episode", systemImage: "waveform.and.mic")
                    }
                }
            }

            Divider()
        }

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

    @ViewBuilder
    private var playlistMenu: some View {
        Menu {
            ForEach(allPlaylists) { playlist in
                Button {
                    PlaylistManager.shared.addEpisode(episode, to: playlist)
                } label: {
                    if PlaylistManager.shared.isInPlaylist(episode, playlist: playlist) {
                        Label(playlist.name, systemImage: "checkmark")
                    } else {
                        Text(playlist.name)
                    }
                }
            }

            if allPlaylists.isEmpty {
                Text("No playlists yet")
            }
        } label: {
            Label("Add to Playlist", systemImage: "music.note.list")
        }
    }
}
