import SwiftUI
import SwiftData

struct StarredView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.miniPlayerVisible) private var miniPlayerVisible
    @Query private var allEpisodes: [Episode]

    private var networkMonitor: NetworkMonitor { NetworkMonitor.shared }

    @State private var sortNewestFirst = true
    @State private var showDownloadedOnly = false
    @State private var showCellularConfirmation = false
    @State private var episodePendingDownload: Episode?
    @State private var selectedEpisode: Episode?
    @State private var displayLimit = 100  // Start with 100, load more on scroll

    /// How many more episodes to load when scrolling
    private let loadMoreIncrement = 50

    private var allStarredEpisodes: [Episode] {
        var episodes = allEpisodes.filter { $0.isStarred }

        if showDownloadedOnly {
            episodes = episodes.filter { $0.localFilePath != nil }
        }

        return episodes.sorted { e1, e2 in
            let date1 = e1.publishedDate ?? .distantPast
            let date2 = e2.publishedDate ?? .distantPast
            return sortNewestFirst ? date1 > date2 : date1 < date2
        }
    }

    private var starredEpisodes: [Episode] {
        Array(allStarredEpisodes.prefix(displayLimit))
    }

    private var totalStarredCount: Int {
        allStarredEpisodes.count
    }

    private var hasMoreStarred: Bool {
        displayLimit < totalStarredCount
    }

    private func loadMoreStarred() {
        if hasMoreStarred {
            displayLimit += loadMoreIncrement
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allEpisodes.filter({ $0.isStarred }).isEmpty {
                    ContentUnavailableView(
                        "No Starred Episodes",
                        systemImage: "star",
                        description: Text("Star episodes to save them here")
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
                                }
                            }
                        }

                        // Sort and filter controls - single row
                        Section {
                            HStack(spacing: 12) {
                                // Sort toggle
                                Button {
                                    sortNewestFirst.toggle()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.up.arrow.down")
                                        Text(sortNewestFirst ? "Newest" : "Oldest")
                                    }
                                    .font(.subheadline)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)

                                // Filter toggle
                                FilterToggleButton(
                                    isOn: $showDownloadedOnly,
                                    icon: "arrow.down.circle.fill",
                                    activeColor: .green
                                )

                                Spacer()
                            }
                        }

                        // Episodes
                        Section {
                            if starredEpisodes.isEmpty {
                                ContentUnavailableView(
                                    "No Downloaded Starred Episodes",
                                    systemImage: "arrow.down.circle",
                                    description: Text("Download starred episodes to see them here")
                                )
                            } else {
                                // Episode count as inline row (not sticky)
                                HStack {
                                    if hasMoreStarred {
                                        Text("Showing \(starredEpisodes.count) of \(totalStarredCount) Episodes")
                                    } else {
                                        Text("\(totalStarredCount) Episodes")
                                    }
                                    Spacer()
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                                ForEach(Array(starredEpisodes.enumerated()), id: \.element.guid) { index, episode in
                                    StarredEpisodeRow(episode: episode)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedEpisode = episode
                                        }
                                        .onAppear {
                                            // Load more when approaching the end
                                            if index >= starredEpisodes.count - 10 && hasMoreStarred {
                                                loadMoreStarred()
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
                                }

                                // Loading indicator at bottom
                                if hasMoreStarred {
                                    HStack {
                                        Spacer()
                                        ProgressView()
                                            .onAppear {
                                                loadMoreStarred()
                                            }
                                        Spacer()
                                    }
                                    .listRowBackground(Color.clear)
                                }
                            }
                        }
                    }
                    .contentMargins(.bottom, miniPlayerVisible ? 60 : 0, for: .scrollContent)
                }
            }
            .navigationTitle("Starred")
            .onAppear {
                // Auto-filter to downloaded when offline
                if !networkMonitor.isConnected {
                    showDownloadedOnly = true
                }
            }
            .onChange(of: sortNewestFirst) { _, _ in displayLimit = 100 }
            .onChange(of: showDownloadedOnly) { _, _ in displayLimit = 100 }
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
}

// MARK: - Starred Episode Row

private struct StarredEpisodeRow: View {
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

                    if let date = episode.publishedDate {
                        if episode.playbackPosition > 0 && !episode.isPlayed {
                            Text(remainingTime)
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Text(date.relativeFormatted)
                        }
                    }

                    if !(episode.playbackPosition > 0 && !episode.isPlayed),
                       let duration = episode.duration {
                        Text("\u{2022}")
                        Text(duration.formattedDuration)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 8) {
                // Star button (always filled since we're in starred view)
                Button {
                    episode.isStarred.toggle()
                } label: {
                    Image(systemName: "star.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                // Playing indicator or download button
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
                } else if episode.localFilePath != nil {
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
                } else if let progress = episode.downloadProgress {
                    Button {
                        DownloadManager.shared.cancelDownload(episode)
                    } label: {
                        CircularProgressView(progress: progress)
                            .frame(width: 22, height: 22)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button {
                        DownloadManager.shared.download(episode)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
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

// MARK: - Filter Toggle Button

struct FilterToggleButton: View {
    @Binding var isOn: Bool
    let icon: String
    let activeColor: Color

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(isOn ? activeColor : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isOn ? activeColor.opacity(0.15) : Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    StarredView()
        .modelContainer(for: Episode.self, inMemory: true)
}
