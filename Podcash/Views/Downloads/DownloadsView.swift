import SwiftUI
import SwiftData

struct DownloadsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allEpisodes: [Episode]

    private var networkMonitor: NetworkMonitor { NetworkMonitor.shared }

    @State private var showDeleteAllConfirmation = false
    @State private var showCellularConfirmation = false
    @State private var episodePendingDownload: Episode?

    private var downloadedEpisodes: [Episode] {
        allEpisodes
            .filter { $0.localFilePath != nil }
            .sorted { ($0.publishedDate ?? .distantPast) > ($1.publishedDate ?? .distantPast) }
    }

    private var downloadingEpisodes: [Episode] {
        allEpisodes
            .filter { $0.downloadProgress != nil && $0.localFilePath == nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if downloadedEpisodes.isEmpty && downloadingEpisodes.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Downloaded episodes will appear here for offline playback")
                    )
                } else {
                    List {
                        // Offline indicator
                        if !networkMonitor.isConnected {
                            Section {
                                HStack {
                                    Image(systemName: "wifi.slash")
                                        .foregroundStyle(.orange)
                                    Text("You're offline")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("Only downloaded episodes available")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        // Currently downloading
                        if !downloadingEpisodes.isEmpty {
                            Section("Downloading") {
                                ForEach(downloadingEpisodes) { episode in
                                    DownloadingEpisodeRow(episode: episode)
                                }
                            }
                        }

                        // Downloaded episodes
                        Section("Downloaded (\(formattedTotalSize))") {
                            ForEach(downloadedEpisodes) { episode in
                                DownloadedEpisodeRow(episode: episode)
                                    .contextMenu {
                                        EpisodeContextMenu(
                                            episode: episode,
                                            onDownloadNeedsConfirmation: {
                                                episodePendingDownload = episode
                                                showCellularConfirmation = true
                                            }
                                        )
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            DownloadManager.shared.deleteDownload(episode)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                if !downloadedEpisodes.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(role: .destructive) {
                                showDeleteAllConfirmation = true
                            } label: {
                                Label("Delete All Downloads", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete All Downloads?",
                isPresented: $showDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    DownloadManager.shared.deleteAllDownloads(context: modelContext)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all downloaded episodes from your device.")
            }
            .alert("Download on Cellular?", isPresented: $showCellularConfirmation) {
                Button("Download") {
                    if let episode = episodePendingDownload {
                        DownloadManager.shared.download(episode)
                    }
                    episodePendingDownload = nil
                }
                Button("Cancel", role: .cancel) {
                    episodePendingDownload = nil
                }
            } message: {
                Text("You're on cellular data. Download anyway?")
            }
        }
    }

    private var formattedTotalSize: String {
        let bytes = DownloadManager.shared.totalDownloadSize(context: modelContext)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Downloaded Episode Row

private struct DownloadedEpisodeRow: View {
    let episode: Episode

    private var progressValue: Double {
        guard let duration = episode.duration, duration > 0 else { return 0 }
        return episode.playbackPosition / duration
    }

    private var remainingTime: String {
        guard let duration = episode.duration else { return "" }
        let remaining = duration - episode.playbackPosition
        return remaining.formattedDuration + " left"
    }

    var body: some View {
        NavigationLink {
            EpisodeDetailView(episode: episode)
        } label: {
            HStack(spacing: 12) {
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
                        .foregroundStyle(episode.isPlayed ? .secondary : .primary)

                    HStack(spacing: 6) {
                        // Progress pie indicator if partially played
                        if episode.playbackPosition > 0 && !episode.isPlayed {
                            ProgressPieView(progress: progressValue)
                                .frame(width: 12, height: 12)
                        }

                        if let podcast = episode.podcast {
                            Text(podcast.title)
                        }
                        if let duration = episode.duration {
                            Text("•")
                            if episode.playbackPosition > 0 && !episode.isPlayed {
                                Text(remainingTime)
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Text(duration.formattedDuration)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .opacity(episode.isPlayed ? 0.7 : 1.0)
        }
    }
}

// MARK: - Downloading Episode Row

private struct DownloadingEpisodeRow: View {
    let episode: Episode

    var body: some View {
        HStack(spacing: 12) {
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

                if let progress = episode.downloadProgress {
                    ProgressView(value: progress)
                        .tint(.accentColor)

                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                DownloadManager.shared.cancelDownload(episode)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    DownloadsView()
        .modelContainer(for: Episode.self, inMemory: true)
}
