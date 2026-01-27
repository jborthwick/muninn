import SwiftUI
import SwiftData

struct AllEpisodesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Podcast.title) private var allPodcasts: [Podcast]
    @Query(sort: \Folder.sortOrder) private var allFolders: [Folder]

    private var networkMonitor: NetworkMonitor { NetworkMonitor.shared }

    /// When true, shows only podcasts not in any folder
    var showUnsortedOnly: Bool = false

    @State private var viewMode: ViewMode = .episodes
    @State private var sortNewestFirst = true
    @State private var showStarredOnly = false
    @State private var showDownloadedOnly = false
    @State private var showCellularConfirmation = false
    @State private var episodePendingDownload: Episode?
    @State private var podcastToUnsubscribe: Podcast?
    @State private var showCreateFolder = false
    @State private var podcastForNewFolder: Podcast?

    private var refreshManager: RefreshManager { RefreshManager.shared }

    enum ViewMode: String, CaseIterable {
        case podcasts = "Podcasts"
        case episodes = "Episodes"
    }

    // Podcasts based on filter mode
    private var podcasts: [Podcast] {
        if showUnsortedOnly {
            return allPodcasts.filter { podcast in
                !allFolders.contains { folder in
                    folder.podcasts.contains { $0.feedURL == podcast.feedURL }
                }
            }
        }
        return Array(allPodcasts)
    }

    // Get all episodes paired with their podcast
    private var allEpisodesWithPodcast: [(episode: Episode, podcast: Podcast)] {
        podcasts.flatMap { podcast in
            podcast.episodes.map { episode in (episode: episode, podcast: podcast) }
        }
    }

    private var title: String {
        showUnsortedOnly ? "Unsorted" : "All Episodes"
    }

    private var icon: String {
        showUnsortedOnly ? "tray" : "list.bullet"
    }

    var body: some View {
        Group {
            if podcasts.isEmpty {
                ContentUnavailableView(
                    showUnsortedOnly ? "No Unsorted Podcasts" : "No Podcasts",
                    systemImage: icon,
                    description: Text(showUnsortedOnly ? "All podcasts are organized in folders" : "Add podcasts to your library first")
                )
            } else {
                List {
                    // Refresh status banner
                    RefreshStatusBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)

                    // View mode picker
                    Section {
                        Picker("View", selection: $viewMode) {
                            ForEach(ViewMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
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

                    if viewMode == .podcasts {
                        podcastsView
                    } else {
                        episodesView
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    // Trigger background refresh and return immediately
                    refreshManager.refreshPodcasts(podcasts, context: modelContext)
                }
            }
        }
        .navigationTitle(title)
        .onAppear {
            if !networkMonitor.isConnected {
                showDownloadedOnly = true
            }
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
        .confirmationDialog(
            "Unsubscribe from \(podcastToUnsubscribe?.title ?? "podcast")?",
            isPresented: Binding(
                get: { podcastToUnsubscribe != nil },
                set: { if !$0 { podcastToUnsubscribe = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                if let podcast = podcastToUnsubscribe {
                    DownloadManager.shared.deleteDownloads(for: podcast)
                    modelContext.delete(podcast)
                }
                podcastToUnsubscribe = nil
            }
            Button("Cancel", role: .cancel) {
                podcastToUnsubscribe = nil
            }
        } message: {
            Text("This will remove the podcast and delete all downloaded episodes.")
        }
        .sheet(isPresented: $showCreateFolder, onDismiss: {
            podcastForNewFolder = nil
        }) {
            EditFolderView(folder: nil, initialPodcast: podcastForNewFolder)
        }
    }

    // MARK: - Podcasts View

    @ViewBuilder
    private var podcastsView: some View {
        Section {
            ForEach(podcasts) { podcast in
                NavigationLink {
                    PodcastDetailView(podcast: podcast)
                } label: {
                    PodcastRowView(podcast: podcast)
                }
                .contextMenu {
                    PodcastContextMenu(
                        podcast: podcast,
                        onUnsubscribe: {
                            podcastToUnsubscribe = podcast
                        },
                        onCreateFolder: { podcastToAdd in
                            podcastForNewFolder = podcastToAdd
                            showCreateFolder = true
                        }
                    )
                }
            }
        } header: {
            Text("\(podcasts.count) Podcasts")
        }
    }

    // MARK: - Episodes View

    @ViewBuilder
    private var episodesView: some View {
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

                // Filter toggles
                FilterToggleButton(
                    isOn: $showStarredOnly,
                    icon: "star.fill",
                    activeColor: .yellow
                )

                FilterToggleButton(
                    isOn: $showDownloadedOnly,
                    icon: "arrow.down.circle.fill",
                    activeColor: .green
                )

                Spacer()
            }
        }

        // Episodes list
        Section {
            if filteredEpisodes.isEmpty {
                ContentUnavailableView(
                    emptyStateTitle,
                    systemImage: emptyStateIcon,
                    description: Text(emptyStateDescription)
                )
            } else {
                ForEach(filteredEpisodes, id: \.episode.guid) { item in
                    AllEpisodesRow(
                        episode: item.episode,
                        podcast: item.podcast,
                        onDownloadNeedsConfirmation: { episode in
                            episodePendingDownload = episode
                            showCellularConfirmation = true
                        }
                    )
                        .contextMenu {
                            EpisodeContextMenu(
                                episode: item.episode,
                                onPlay: {
                                    playEpisode(item.episode)
                                },
                                onDownloadNeedsConfirmation: {
                                    episodePendingDownload = item.episode
                                    showCellularConfirmation = true
                                }
                            )
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                item.episode.isStarred.toggle()
                                if item.episode.isStarred && item.episode.localFilePath == nil {
                                    let result = DownloadManager.shared.checkDownloadAllowed(item.episode, isAutoDownload: true, context: modelContext)
                                    switch result {
                                    case .started:
                                        DownloadManager.shared.download(item.episode)
                                    case .needsConfirmation:
                                        episodePendingDownload = item.episode
                                        showCellularConfirmation = true
                                    case .blocked, .alreadyDownloaded, .alreadyDownloading:
                                        break
                                    }
                                }
                            } label: {
                                Label(
                                    item.episode.isStarred ? "Unstar" : "Star",
                                    systemImage: item.episode.isStarred ? "star.slash" : "star"
                                )
                            }
                            .tint(.yellow)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                QueueManager.shared.addToQueue(item.episode)
                            } label: {
                                Label("Queue", systemImage: "text.badge.plus")
                            }
                            .tint(.indigo)

                            Button {
                                QueueManager.shared.playNext(item.episode)
                            } label: {
                                Label("Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            .tint(.blue)
                        }
                }
            }
        } header: {
            Text("\(filteredEpisodes.count) Episodes")
        }
    }

    // MARK: - Filtered Episodes

    private var filteredEpisodes: [(episode: Episode, podcast: Podcast)] {
        var items = allEpisodesWithPodcast

        if showStarredOnly {
            items = items.filter { $0.episode.isStarred }
        }

        if showDownloadedOnly {
            items = items.filter { $0.episode.localFilePath != nil }
        }

        return items.sorted { e1, e2 in
            let date1 = e1.episode.publishedDate ?? .distantPast
            let date2 = e2.episode.publishedDate ?? .distantPast
            return sortNewestFirst ? date1 > date2 : date1 < date2
        }
    }

    // MARK: - Empty State

    private var emptyStateTitle: String {
        if showStarredOnly && showDownloadedOnly {
            return "No Starred Downloads"
        } else if showStarredOnly {
            return "No Starred Episodes"
        } else if showDownloadedOnly {
            return "No Downloaded Episodes"
        } else {
            return "No Episodes"
        }
    }

    private var emptyStateIcon: String {
        if showDownloadedOnly {
            return "arrow.down.circle"
        } else if showStarredOnly {
            return "star"
        } else {
            return "list.bullet"
        }
    }

    private var emptyStateDescription: String {
        if showDownloadedOnly && !networkMonitor.isConnected {
            return "Download episodes while online to play offline"
        } else if showStarredOnly {
            return "Star episodes to see them here"
        } else {
            return "No episodes available"
        }
    }

    // MARK: - Actions

    private func playEpisode(_ episode: Episode) {
        if !networkMonitor.isConnected && episode.localFilePath == nil {
            return
        }

        if episode.localFilePath == nil {
            DownloadManager.shared.download(episode)
        }

        AudioPlayerManager.shared.play(episode)
    }
}

// MARK: - All Episodes Row

private struct AllEpisodesRow: View {
    @Environment(\.modelContext) private var modelContext
    let episode: Episode
    let podcast: Podcast
    var onDownloadNeedsConfirmation: ((Episode) -> Void)?

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
                CachedAsyncImage(url: URL(string: podcast.artworkURL ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
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

                        Text(podcast.title)
                            .lineLimit(1)
                        if let date = episode.publishedDate {
                            Text("•")
                            if episode.playbackPosition > 0 && !episode.isPlayed {
                                Text(remainingTime)
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Text(date.relativeFormatted)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                // Action buttons
                HStack(spacing: 12) {
                    // Star button
                    Button {
                        episode.isStarred.toggle()
                        if episode.isStarred && episode.localFilePath == nil {
                            attemptDownload(isAutoDownload: true)
                        }
                    } label: {
                        Image(systemName: episode.isStarred ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundStyle(episode.isStarred ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)

                    // Download button
                    if episode.localFilePath != nil {
                        Button {
                            DownloadManager.shared.deleteDownload(episode)
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.plain)
                    } else if let progress = episode.downloadProgress {
                        Button {
                            DownloadManager.shared.cancelDownload(episode)
                        } label: {
                            CircularProgressView(progress: progress)
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            attemptDownload(isAutoDownload: false)
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .opacity(episode.isPlayed ? 0.7 : 1.0)
        }
    }

    private func attemptDownload(isAutoDownload: Bool) {
        let result = DownloadManager.shared.checkDownloadAllowed(episode, isAutoDownload: isAutoDownload, context: modelContext)
        switch result {
        case .started:
            DownloadManager.shared.download(episode)
        case .needsConfirmation:
            onDownloadNeedsConfirmation?(episode)
        case .blocked, .alreadyDownloaded, .alreadyDownloading:
            break
        }
    }
}

#Preview {
    NavigationStack {
        AllEpisodesView()
    }
    .modelContainer(for: [Podcast.self, Folder.self], inMemory: true)
}
