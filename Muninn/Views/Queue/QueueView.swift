import SwiftUI
import SwiftData

struct QueueView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.miniPlayerVisible) private var miniPlayerVisible
    @Query(sort: \QueueItem.sortOrder) private var queueItems: [QueueItem]

    private var networkMonitor: NetworkMonitor { NetworkMonitor.shared }
    private var playerManager: AudioPlayerManager { AudioPlayerManager.shared }

    @State private var showClearConfirmation = false

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
                        // Now playing section
                        if let currentEpisode = playerManager.currentEpisode {
                            Section("Now Playing") {
                                NowPlayingRow(episode: currentEpisode)
                            }
                        }

                        // Offline indicator
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

                        // Queue section
                        Section("Up Next") {
                            ForEach(queueItems) { item in
                                if let episode = item.episode {
                                    HStack(spacing: 0) {
                                        Button {
                                            if let index = queueItems.firstIndex(where: { $0.id == item.id }) {
                                                deleteItems(at: IndexSet(integer: index))
                                            }
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundStyle(.red)
                                                .font(.title3)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 8)

                                        QueueEpisodeRow(episode: episode)
                                            .onTapGesture {
                                                playFromQueue(item)
                                            }
                                    }
                                }
                            }
                            .onMove(perform: moveItems)
                        }
                        .environment(\.editMode, .constant(.active))
                    }
                    .listStyle(.plain)
                    .contentMargins(.bottom, miniPlayerVisible ? 60 : 0, for: .scrollContent)
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
        }
    }

    private func playFromQueue(_ item: QueueItem) {
        guard let episode = item.episode else { return }

        // Check if offline and not downloaded
        if !networkMonitor.isConnected && episode.localFilePath == nil {
            return
        }

        // Remove from queue and play
        modelContext.delete(item)
        try? modelContext.save()

        // Auto-download when playing
        if episode.localFilePath == nil {
            DownloadManager.shared.download(episode)
        }

        AudioPlayerManager.shared.play(episode)
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            let item = queueItems[index]
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        QueueManager.shared.moveItem(from: source, to: destination)
    }
}

// MARK: - Now Playing Row

private struct NowPlayingRow: View {
    let episode: Episode
    private var playerManager: AudioPlayerManager { AudioPlayerManager.shared }

    var body: some View {
        HStack(spacing: 12) {
            // Podcast artwork
            CachedAsyncImage(url: URL(string: episode.podcast?.artworkURL ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 6))

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

            // Play/Pause button
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
}

// MARK: - Queue Episode Row

private struct QueueEpisodeRow: View {
    let episode: Episode

    var body: some View {
        HStack(spacing: 12) {
            // Podcast artwork
            CachedAsyncImage(url: URL(string: episode.podcast?.artworkURL ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 6))

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

            // Download indicator
            if episode.localFilePath != nil {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if let progress = episode.downloadProgress {
                CircularProgressView(progress: progress)
                    .frame(width: 16, height: 16)
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    QueueView()
        .modelContainer(for: QueueItem.self, inMemory: true)
}
