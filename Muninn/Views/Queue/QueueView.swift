import SwiftUI
import SwiftData

struct QueueView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \QueueItem.sortOrder) private var queueItems: [QueueItem]

    private var networkMonitor: NetworkMonitor { NetworkMonitor.shared }
    private var playerManager: AudioPlayerManager { AudioPlayerManager.shared }

    @State private var showClearConfirmation = false
    @State private var selectedEpisode: Episode?

    var body: some View {
        NavigationStack {
            Group {
                if queueItems.isEmpty {
                    ContentUnavailableView(
                        "Queue Empty",
                        systemImage: "list.bullet",
                        description: Text("Add episodes to play next")
                    )
                } else {
                    List {
                        if let currentEpisode = playerManager.currentEpisode {
                            Section("Now Playing") {
                                NowPlayingRow(episode: currentEpisode)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedEpisode = currentEpisode
                                    }
                            }
                        }

                        if !networkMonitor.isConnected {
                            Section {
                                HStack {
                                    Image(systemName: "wifi.slash")
                                        .foregroundStyle(.orange)
                                    Text("You're offline")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                            }
                        }

                        Section("Up Next") {
                            ForEach(queueItems) { item in
                                if let episode = item.episode {
                                    QueueEpisodeRow(episode: episode)
                                        .equatable()
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedEpisode = episode
                                        }
                                }
                            }
                            .onMove(perform: moveItems)
                            .onDelete(perform: deleteItems)
                        }
                        .environment(\.editMode, .constant(.active))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Up Next")
            .toolbar {
                if !queueItems.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            Text("Clear")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Clear Queue?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) {
                    QueueManager.shared.clearQueue()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all episodes from your queue.")
            }
            .sheet(item: $selectedEpisode) { episode in
                EpisodeDetailView(episode: episode)
            }
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(queueItems[index])
        }
        try? modelContext.save()
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        // @Query is already sorted — pass the snapshot through so reorder doesn't refetch.
        withTransaction(Transaction(animation: nil)) {
            QueueManager.shared.moveItems(queueItems, from: source, to: destination)
        }
    }
}

// MARK: - Now Playing Row

private struct NowPlayingRow: View {
    let episode: Episode

    var body: some View {
        HStack(spacing: 12) {
            QueueArtworkView(artworkURL: episode.podcast?.artworkURL)

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(2)

                if let podcast = episode.podcast {
                    Text(podcast.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            NowPlayingTransportButton()
        }
    }
}

/// Isolates play/pause observation so queue rows don't re-render on every tick.
private struct NowPlayingTransportButton: View {
    private var playerManager: AudioPlayerManager { AudioPlayerManager.shared }

    var body: some View {
        Button {
            playerManager.togglePlayPause()
        } label: {
            Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.title)
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Queue Episode Row

private struct QueueEpisodeRow: View, Equatable {
    let episode: Episode

    static func == (lhs: QueueEpisodeRow, rhs: QueueEpisodeRow) -> Bool {
        lhs.episode.guid == rhs.episode.guid
            && lhs.episode.title == rhs.episode.title
            && lhs.episode.localFilePath == rhs.episode.localFilePath
            && lhs.episode.downloadProgress == rhs.episode.downloadProgress
            && lhs.episode.podcast?.feedURL == rhs.episode.podcast?.feedURL
    }

    var body: some View {
        HStack(spacing: 12) {
            QueueArtworkView(artworkURL: episode.podcast?.artworkURL)

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let podcast = episode.podcast {
                        Text(podcast.title)
                    }
                    if let duration = episode.duration {
                        Text("•")
                        Text(duration.formattedDuration)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            QueueDownloadIndicator(
                downloadProgress: episode.downloadProgress,
                isDownloaded: episode.localFilePath != nil
            )
        }
    }
}

private struct QueueArtworkView: View, Equatable {
    let artworkURL: String?

    static func == (lhs: QueueArtworkView, rhs: QueueArtworkView) -> Bool {
        lhs.artworkURL == rhs.artworkURL
    }

    var body: some View {
        CachedAsyncImage(url: URL(string: artworkURL ?? "")) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.2))
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct QueueDownloadIndicator: View, Equatable {
    let downloadProgress: Double?
    let isDownloaded: Bool

    var body: some View {
        Group {
            if let progress = downloadProgress {
                CircularProgressView(progress: progress)
                    .frame(width: 16, height: 16)
            } else if isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }
}

#Preview {
    QueueView()
        .modelContainer(for: QueueItem.self, inMemory: true)
}
