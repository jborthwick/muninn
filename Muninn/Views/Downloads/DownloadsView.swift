import SwiftUI
import SwiftData

struct DownloadsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.miniPlayerVisible) private var miniPlayerVisible
    @Query private var allEpisodes: [Episode]

    private var networkMonitor: NetworkMonitor { NetworkMonitor.shared }

    @State private var showDeleteAllConfirmation = false
    @State private var showCellularConfirmation = false
    @State private var episodePendingDownload: Episode?
    @State private var selectedEpisode: Episode?
    @State private var displayLimit = 100  // Start with 100, load more on scroll

    /// How many more episodes to load when scrolling
    private let loadMoreIncrement = 50

    private var allDownloadedEpisodes: [Episode] {
        allEpisodes
            .filter { $0.localFilePath != nil }
            .sorted { ($0.publishedDate ?? .distantPast) > ($1.publishedDate ?? .distantPast) }
    }

    private var downloadedEpisodes: [Episode] {
        Array(allDownloadedEpisodes.prefix(displayLimit))
    }

    private var totalDownloadedCount: Int {
        allDownloadedEpisodes.count
    }

    private var hasMoreDownloads: Bool {
        displayLimit < totalDownloadedCount
    }

    private func loadMoreDownloads() {
        if hasMoreDownloads {
            displayLimit += loadMoreIncrement
        }
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
                        Section {
                            // Episode count as inline row (not sticky)
                            HStack {
                                if hasMoreDownloads {
                                    Text("Showing \(downloadedEpisodes.count) of \(totalDownloadedCount) Downloaded (\(formattedTotalSize))")
                                } else {
                                    Text("Downloaded (\(formattedTotalSize))")
                                }
                                Spacer()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                            ForEach(Array(downloadedEpisodes.enumerated()), id: \.element.guid) { index, episode in
                                DownloadedEpisodeRow(episode: episode)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedEpisode = episode
                                    }
                                    .onAppear {
                                        // Load more when approaching the end
                                        if index >= downloadedEpisodes.count - 10 && hasMoreDownloads {
                                            loadMoreDownloads()
                                        }
                                    }
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

                            // Loading indicator at bottom
                            if hasMoreDownloads {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                        .onAppear {
                                            loadMoreDownloads()
                                        }
                                    Spacer()
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                    .contentMargins(.bottom, miniPlayerVisible ? 60 : 0, for: .scrollContent)
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
            .sheet(item: $selectedEpisode) { episode in
                EpisodeDetailView(episode: episode)
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

    @State private var showDeleteDownloadConfirmation = false

    private var isCurrentlyPlaying: Bool {
        AudioPlayerManager.shared.currentEpisode?.guid == episode.guid
    }

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
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .foregroundStyle(episode.isPlayed ? .secondary : .primary)

                if let podcast = episode.podcast {
                    Text(podcast.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    // Progress pie indicator if partially played
                    if episode.playbackPosition > 0 && !episode.isPlayed {
                        ProgressPieView(progress: progressValue)
                            .frame(width: 12, height: 12)
                    }

                    if let duration = episode.duration {
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

            if isCurrentlyPlaying {
                Button {
                    AudioPlayerManager.shared.togglePlayPause()
                } label: {
                    Image(systemName: AudioPlayerManager.shared.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            } else if episode.isPlayed {
                Button {
                    showDeleteDownloadConfirmation = true
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            } else {
                Button {
                    showDeleteDownloadConfirmation = true
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .opacity(episode.isPlayed ? 0.7 : 1.0)
        .alert("Delete Download?", isPresented: $showDeleteDownloadConfirmation) {
            Button("Delete", role: .destructive) {
                DownloadManager.shared.deleteDownload(episode)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The downloaded file will be removed from your device.")
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
                // Cancel the download and clear progress
                DownloadManager.shared.cancelDownload(episode)
                // Force clear progress in case it's stuck
                episode.downloadProgress = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                // Force clear stuck download
                DownloadManager.shared.cancelDownload(episode)
                episode.downloadProgress = nil
            } label: {
                Label("Clear", systemImage: "trash")
            }
        }
    }
}

#Preview {
    DownloadsView()
        .modelContainer(for: Episode.self, inMemory: true)
}
