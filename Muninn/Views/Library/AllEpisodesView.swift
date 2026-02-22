import SwiftUI
import SwiftData

struct AllEpisodesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.miniPlayerVisible) private var miniPlayerVisible
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
    @State private var selectedEpisode: Episode?
    @State private var podcastToUnsubscribe: Podcast?
    @State private var showCreateFolder = false
    @State private var podcastForNewFolder: Podcast?
    @State private var displayLimit = 100  // Start with 100, load more on scroll
    
    // Performance optimization: Load episodes on-demand instead of all at once
    @State private var loadedEpisodes: [Episode] = []
    @State private var totalEpisodeCount: Int = 0
    @State private var isLoadingEpisodes = false

    // Cache only the folder lookup (rarely changes) - filtered episodes computed fresh for real-time updates
    @State private var cachedPodcastsInFolders: Set<String> = []

    private var refreshManager: RefreshManager { RefreshManager.shared }

    enum ViewMode: String, CaseIterable {
        case podcasts = "Podcasts"
        case episodes = "Episodes"
    }

    // Podcasts based on filter mode (uses cached set)
    private var podcasts: [Podcast] {
        if showUnsortedOnly {
            return allPodcasts.filter { !cachedPodcastsInFolders.contains($0.feedURL) }
        }
        return Array(allPodcasts)
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
                .contentMargins(.bottom, miniPlayerVisible ? 60 : 0, for: .scrollContent)
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
            rebuildFolderCache()
            loadEpisodes()
        }
        .onChange(of: sortNewestFirst) { _, _ in
            displayLimit = 100
            loadEpisodes()
        }
        .onChange(of: showStarredOnly) { _, _ in
            displayLimit = 100
            loadEpisodes()
        }
        .onChange(of: showDownloadedOnly) { _, _ in
            displayLimit = 100
            loadEpisodes()
        }
        .onChange(of: allFolders.count) { _, _ in
            rebuildFolderCache()
            loadEpisodes()
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
                    try? modelContext.save()
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
            if isLoadingEpisodes && loadedEpisodes.isEmpty {
                // Initial loading state
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading episodes...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 40)
                    Spacer()
                }
            } else if filteredEpisodes.isEmpty {
                ContentUnavailableView(
                    emptyStateTitle,
                    systemImage: emptyStateIcon,
                    description: Text(emptyStateDescription)
                )
            } else {
                // Episode count as inline row (not sticky)
                HStack {
                    if hasMoreEpisodes {
                        Text("Showing \(filteredEpisodes.count) of \(totalEpisodeCount) Episodes")
                    } else {
                        Text("\(totalEpisodeCount) Episodes")
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                ForEach(Array(filteredEpisodes.enumerated()), id: \.element.episode.guid) { index, item in
                    AllEpisodesRow(
                        episode: item.episode,
                        podcast: item.podcast,
                        onDownloadNeedsConfirmation: { episode in
                            episodePendingDownload = episode
                            showCellularConfirmation = true
                        }
                    )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedEpisode = item.episode
                        }
                        .onAppear {
                            // Load more when approaching the end
                            if index >= filteredEpisodes.count - 10 && hasMoreEpisodes {
                                loadMoreEpisodes()
                            }
                        }
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
                                if QueueManager.shared.isInQueue(item.episode) {
                                    QueueManager.shared.removeFromQueue(item.episode)
                                } else {
                                    QueueManager.shared.addToQueue(item.episode)
                                }
                            } label: {
                                Label(
                                    QueueManager.shared.isInQueue(item.episode) ? "Dequeue" : "Queue",
                                    systemImage: QueueManager.shared.isInQueue(item.episode) ? "text.badge.checkmark" : "text.badge.plus"
                                )
                            }
                            .tint(QueueManager.shared.isInQueue(item.episode) ? .indigo : .indigo)

                            Button {
                                QueueManager.shared.playNext(item.episode)
                            } label: {
                                Label("Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            .tint(.blue)
                        }
                }

                // Loading indicator at bottom
                if hasMoreEpisodes {
                    HStack {
                        Spacer()
                        ProgressView()
                            .onAppear {
                                loadMoreEpisodes()
                            }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
    }

    // MARK: - Filtered Episodes (optimized for large datasets)

    /// How many more episodes to load when scrolling
    private let loadMoreIncrement = 50

    /// Filtered episodes with podcast relationships - only what's currently loaded
    private var filteredEpisodes: [(episode: Episode, podcast: Podcast)] {
        loadedEpisodes.compactMap { episode in
            guard let podcast = episode.podcast else { return nil }
            return (episode: episode, podcast: podcast)
        }
    }

    private var hasMoreEpisodes: Bool {
        loadedEpisodes.count < totalEpisodeCount
    }

    /// Load episodes from database with filters applied at query level (much faster)
    private func loadEpisodes(limit: Int? = nil) {
        guard !isLoadingEpisodes else { return }
        isLoadingEpisodes = true
        
        Task {
            await MainActor.run {
                do {
                    // Build predicate based on filters
                    let finalPredicate: Predicate<Episode>? = {
                        if showStarredOnly && showDownloadedOnly {
                            return #Predicate<Episode> { $0.isStarred == true && $0.localFilePath != nil }
                        } else if showStarredOnly {
                            return #Predicate<Episode> { $0.isStarred == true }
                        } else if showDownloadedOnly {
                            return #Predicate<Episode> { $0.localFilePath != nil }
                        } else {
                            return nil
                        }
                    }()
                    
                    // Create descriptor with sort and limit
                    var descriptor = FetchDescriptor<Episode>(
                        predicate: finalPredicate,
                        sortBy: [SortDescriptor(\Episode.publishedDate, order: sortNewestFirst ? .reverse : .forward)]
                    )
                    
                    descriptor.fetchLimit = limit ?? displayLimit
                    
                    // Fetch episodes
                    let episodes = try modelContext.fetch(descriptor)
                    
                    // Filter for unsorted mode if needed (can't do this in predicate easily)
                    let filteredForUnsorted: [Episode]
                    if showUnsortedOnly {
                        filteredForUnsorted = episodes.filter { episode in
                            guard let feedURL = episode.podcast?.feedURL else { return false }
                            return !cachedPodcastsInFolders.contains(feedURL)
                        }
                    } else {
                        filteredForUnsorted = episodes
                    }
                    
                    loadedEpisodes = filteredForUnsorted
                    
                    // Get total count (without limit) - only count, don't load all data
                    let countDescriptor = FetchDescriptor<Episode>(predicate: finalPredicate)
                    let allEpisodes = try modelContext.fetch(countDescriptor)
                    totalEpisodeCount = showUnsortedOnly ? allEpisodes.filter { episode in
                        guard let feedURL = episode.podcast?.feedURL else { return false }
                        return !cachedPodcastsInFolders.contains(feedURL)
                    }.count : allEpisodes.count
                    
                } catch {
                    print("Error loading episodes: \(error)")
                }
                
                isLoadingEpisodes = false
            }
        }
    }
    
    private func loadMoreEpisodes() {
        guard !isLoadingEpisodes && hasMoreEpisodes else { return }
        displayLimit += loadMoreIncrement
        loadEpisodes(limit: displayLimit)
    }

    // MARK: - Cache Management

    private func rebuildFolderCache() {
        // Only cache the folder lookup - filtered episodes are computed fresh
        cachedPodcastsInFolders = Set(allFolders.flatMap { $0.podcasts.map { $0.feedURL } })
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
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .foregroundStyle(episode.isPlayed ? .secondary : .primary)

                Text(podcast.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

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
                        attemptDownload(isAutoDownload: false)
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
                DownloadManager.shared.deleteDownload(episode, context: modelContext)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The downloaded file will be removed from your device.")
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
