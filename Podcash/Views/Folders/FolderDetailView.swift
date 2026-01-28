import SwiftUI
import SwiftData

struct FolderDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Podcast.title) private var allPodcasts: [Podcast]
    @Bindable var folder: Folder

    private var networkMonitor: NetworkMonitor { NetworkMonitor.shared }

    @Environment(\.dismiss) private var dismiss

    @State private var viewMode: ViewMode = .episodes
    @State private var sortNewestFirst = true
    @State private var showStarredOnly = false
    @State private var showDownloadedOnly = false
    @State private var showManagePodcasts = false
    @State private var showEditFolder = false
    @State private var showDeleteConfirmation = false
    @State private var showCreateFolder = false
    @State private var podcastForNewFolder: Podcast?
    @State private var showCellularConfirmation = false
    @State private var episodePendingDownload: Episode?
    @State private var selectedEpisode: Episode?
    @State private var podcastToUnsubscribe: Podcast?
    @State private var displayLimit = 100  // Start with 100, load more on scroll

    private var refreshManager: RefreshManager { RefreshManager.shared }

    enum ViewMode: String, CaseIterable {
        case podcasts = "Podcasts"
        case episodes = "Episodes"
    }

    // Get podcasts in this folder by checking the relationship
    private var podcastsInFolder: [Podcast] {
        allPodcasts.filter { podcast in
            folder.podcasts.contains { $0.feedURL == podcast.feedURL }
        }
    }

    // Dictionary for fast podcast lookup by episode
    private var podcastByEpisodeGuid: [String: Podcast] {
        var dict: [String: Podcast] = [:]
        for podcast in podcastsInFolder {
            for episode in podcast.episodes {
                dict[episode.guid] = podcast
            }
        }
        return dict
    }

    // Get all episodes in folder (without creating tuples yet)
    private var allEpisodesInFolder: [Episode] {
        podcastsInFolder.flatMap { $0.episodes }
    }

    var body: some View {
        Group {
            if podcastsInFolder.isEmpty {
                ContentUnavailableView(
                    "No Podcasts",
                    systemImage: "folder",
                    description: Text("Tap + to add podcasts to this folder")
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
                .refreshable {
                    // Trigger background refresh and return immediately
                    refreshManager.refreshPodcasts(podcastsInFolder, context: modelContext)
                }
            }
        }
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showManagePodcasts = true
                    } label: {
                        Label("Manage Podcasts", systemImage: "plus.circle")
                    }

                    Button {
                        showEditFolder = true
                    } label: {
                        Label("Rename Folder", systemImage: "pencil")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Folder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showManagePodcasts) {
            ManageFolderPodcastsView(folder: folder, allPodcasts: allPodcasts)
        }
        .sheet(isPresented: $showEditFolder) {
            EditFolderView(folder: folder)
        }
        .sheet(isPresented: $showCreateFolder, onDismiss: {
            podcastForNewFolder = nil
        }) {
            EditFolderView(folder: nil, initialPodcast: podcastForNewFolder)
        }
        .confirmationDialog(
            "Delete \(folder.name)?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteFolder()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the folder. Podcasts will remain in your library.")
        }
        .onAppear {
            if !networkMonitor.isConnected {
                showDownloadedOnly = true
            }
        }
        .onChange(of: sortNewestFirst) { _, _ in displayLimit = 100 }
        .onChange(of: showStarredOnly) { _, _ in displayLimit = 100 }
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
    }

    // MARK: - Podcasts View

    @ViewBuilder
    private var podcastsView: some View {
        Section {
            ForEach(podcastsInFolder) { podcast in
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

                    Divider()

                    Button(role: .destructive) {
                        removePodcastFromFolder(podcast)
                    } label: {
                        Label("Remove from Folder", systemImage: "folder.badge.minus")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        removePodcastFromFolder(podcast)
                    } label: {
                        Label("Remove", systemImage: "folder.badge.minus")
                    }
                }
            }
        } header: {
            Text("\(podcastsInFolder.count) Podcasts")
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
                ForEach(Array(filteredEpisodes.enumerated()), id: \.element.episode.guid) { index, item in
                    FolderEpisodeRow(
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
        } header: {
            if hasMoreEpisodes {
                Text("Showing \(filteredEpisodes.count) of \(totalEpisodeCount) Episodes")
            } else {
                Text("\(totalEpisodeCount) Episodes")
            }
        }
    }

    // MARK: - Filtered Episodes

    /// How many more episodes to load when scrolling
    private let loadMoreIncrement = 50

    /// Filtered and sorted episodes without tuple conversion (fast for counting)
    private var filteredEpisodesRaw: [Episode] {
        var episodes = allEpisodesInFolder

        if showStarredOnly {
            episodes = episodes.filter { $0.isStarred }
        }

        if showDownloadedOnly {
            episodes = episodes.filter { $0.localFilePath != nil }
        }

        return episodes.sorted { e1, e2 in
            let date1 = e1.publishedDate ?? .distantPast
            let date2 = e2.publishedDate ?? .distantPast
            return sortNewestFirst ? date1 > date2 : date1 < date2
        }
    }

    /// Only create tuples for episodes we're actually displaying
    private var filteredEpisodes: [(episode: Episode, podcast: Podcast)] {
        let lookup = podcastByEpisodeGuid
        return filteredEpisodesRaw.prefix(displayLimit).compactMap { episode in
            guard let podcast = lookup[episode.guid] else { return nil }
            return (episode: episode, podcast: podcast)
        }
    }

    private var totalEpisodeCount: Int {
        filteredEpisodesRaw.count
    }

    private var hasMoreEpisodes: Bool {
        displayLimit < totalEpisodeCount
    }

    private func loadMoreEpisodes() {
        if hasMoreEpisodes {
            displayLimit += loadMoreIncrement
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

    private func removePodcastFromFolder(_ podcast: Podcast) {
        if let index = folder.podcasts.firstIndex(where: { $0.feedURL == podcast.feedURL }) {
            folder.podcasts.remove(at: index)
            try? modelContext.save()
        }
    }

    private func deleteFolder() {
        modelContext.delete(folder)
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Manage Folder Podcasts View

struct ManageFolderPodcastsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var folder: Folder
    let allPodcasts: [Podcast]

    var body: some View {
        NavigationStack {
            List {
                if allPodcasts.isEmpty {
                    ContentUnavailableView(
                        "No Podcasts",
                        systemImage: "mic",
                        description: Text("Add podcasts to your library first")
                    )
                } else {
                    Section {
                        ForEach(allPodcasts) { podcast in
                            Button {
                                togglePodcast(podcast)
                            } label: {
                                HStack {
                                    // Podcast artwork
                                    CachedAsyncImage(url: URL(string: podcast.artworkURL ?? "")) { image in
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.secondary.opacity(0.2))
                                    }
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                    Text(podcast.title)
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    if isInFolder(podcast) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("Tap to add or remove podcasts from this folder")
                    }
                }
            }
            .navigationTitle("Manage Podcasts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func isInFolder(_ podcast: Podcast) -> Bool {
        folder.podcasts.contains { $0.feedURL == podcast.feedURL }
    }

    private func togglePodcast(_ podcast: Podcast) {
        if let index = folder.podcasts.firstIndex(where: { $0.feedURL == podcast.feedURL }) {
            folder.podcasts.remove(at: index)
        } else {
            folder.podcasts.append(podcast)
        }
        try? modelContext.save()
    }
}

// MARK: - Folder Episode Row

private struct FolderEpisodeRow: View {
    @Environment(\.modelContext) private var modelContext
    let episode: Episode
    let podcast: Podcast  // Explicitly passed to avoid relationship issues
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
    let folder = Folder(name: "News", colorHex: "FF3B30")
    return NavigationStack {
        FolderDetailView(folder: folder)
    }
    .modelContainer(for: [Folder.self, Podcast.self], inMemory: true)
}
