import SwiftUI
import SwiftData

struct PodcastDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.miniPlayerVisible) private var miniPlayerVisible
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Folder.sortOrder) private var allFolders: [Folder]
    let podcast: Podcast

    private var networkMonitor: NetworkMonitor { NetworkMonitor.shared }

    @State private var sortNewestFirst = true
    @State private var showStarredOnly = false
    @State private var showDownloadedOnly = false
    @State private var isRefreshing = false
    @State private var showFolderPicker = false
    @State private var showUnsubscribeConfirmation = false
    @State private var shareText: String?
    @State private var isPreparingShare = false
    @State private var showCellularConfirmation = false
    @State private var episodePendingDownload: Episode?
    @State private var selectedEpisode: Episode?
    @State private var displayLimit = 100  // Start with 100, load more on scroll

    var body: some View {
        List {
            // Header section
            Section {
                PodcastHeaderView(podcast: podcast, folders: podcast.folders) {
                    showFolderPicker = true
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

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

                    // Filter toggles
                    FilterToggle(
                        isOn: $showStarredOnly,
                        icon: "star.fill",
                        activeColor: .yellow
                    )

                    FilterToggle(
                        isOn: $showDownloadedOnly,
                        icon: "arrow.down.circle.fill",
                        activeColor: .green
                    )

                    Spacer()

                    // Auto-download toggle
                    Button {
                        podcast.autoDownloadNewEpisodes.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: podcast.autoDownloadNewEpisodes ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                            Text("Auto")
                                .font(.caption)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(podcast.autoDownloadNewEpisodes ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.1))
                        .foregroundStyle(podcast.autoDownloadNewEpisodes ? .blue : .secondary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Episodes
            Section {
                if filteredEpisodes.isEmpty {
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

                    ForEach(Array(filteredEpisodes.enumerated()), id: \.element.guid) { index, episode in
                        EpisodeRowView(episode: episode)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedEpisode = episode
                            }
                            .onAppear {
                                // Load more when approaching the end
                                if index >= filteredEpisodes.count - 10 && hasMoreEpisodes {
                                    loadMoreEpisodes()
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
                            .swipeActions(edge: .leading) {
                                Button {
                                    toggleStar(episode)
                                } label: {
                                    Label(
                                        episode.isStarred ? "Unstar" : "Star",
                                        systemImage: episode.isStarred ? "star.slash" : "star"
                                    )
                                }
                                .tint(.yellow)
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    QueueManager.shared.addToQueue(episode)
                                } label: {
                                    Label("Queue", systemImage: "text.badge.plus")
                                }
                                .tint(.indigo)

                                Button {
                                    QueueManager.shared.playNext(episode)
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
        .listStyle(.plain)
        .contentMargins(.bottom, miniPlayerVisible ? 60 : 0, for: .scrollContent)
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refreshPodcast()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 16) {
                    // Share button
                    Button {
                        Task {
                            await prepareAndShare()
                        }
                    } label: {
                        if isPreparingShare {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(isPreparingShare)

                    // Folder button
                    Button {
                        showFolderPicker = true
                    } label: {
                        Image(systemName: podcast.folders.isEmpty ? "folder.badge.plus" : "folder.fill")
                            .foregroundStyle(podcast.folders.isEmpty ? Color.secondary : Color.accentColor)
                    }

                    // Subscribed toggle
                    Button {
                        showUnsubscribeConfirmation = true
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { shareText != nil },
            set: { if !$0 { shareText = nil } }
        )) {
            if let text = shareText {
                ShareSheet(items: [text])
            }
        }
        .confirmationDialog(
            "Unsubscribe from \(podcast.title)?",
            isPresented: $showUnsubscribeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                unsubscribe()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the podcast and delete all downloaded episodes.")
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerView(podcast: podcast, allFolders: allFolders)
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
        .onAppear {
            // Auto-filter to downloaded when offline
            if !networkMonitor.isConnected {
                showDownloadedOnly = true
            }

            // Pre-lookup public feed URL for sharing
            if podcast.isPrivateFeed && podcast.publicFeedURL == nil {
                Task {
                    await lookupPublicFeed()
                    try? modelContext.save()
                }
            }
        }
        .onChange(of: sortNewestFirst) { _, _ in displayLimit = 100 }
        .onChange(of: showStarredOnly) { _, _ in displayLimit = 100 }
        .onChange(of: showDownloadedOnly) { _, _ in displayLimit = 100 }
    }

    /// How many more episodes to load when scrolling
    private let loadMoreIncrement = 50

    private var allFilteredEpisodes: [Episode] {
        var episodes = podcast.episodes

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

    private var filteredEpisodes: [Episode] {
        Array(allFilteredEpisodes.prefix(displayLimit))
    }

    private var totalEpisodeCount: Int {
        allFilteredEpisodes.count
    }

    private var hasMoreEpisodes: Bool {
        displayLimit < totalEpisodeCount
    }

    private func loadMoreEpisodes() {
        if hasMoreEpisodes {
            displayLimit += loadMoreIncrement
        }
    }

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

    private func playEpisode(_ episode: Episode) {
        // Check if offline and not downloaded
        if !networkMonitor.isConnected && episode.localFilePath == nil {
            // Can't play - show alert or do nothing
            return
        }

        // Auto-download when playing
        if episode.localFilePath == nil {
            DownloadManager.shared.download(episode)
        }

        AudioPlayerManager.shared.play(episode)
    }

    private func toggleStar(_ episode: Episode) {
        episode.isStarred.toggle()

        // Auto-download when starring
        if episode.isStarred && episode.localFilePath == nil {
            DownloadManager.shared.download(episode)
        }
    }

    private func refreshPodcast() async {
        isRefreshing = true
        do {
            _ = try await FeedService.shared.refreshPodcast(podcast, context: modelContext)
        } catch {
            // Could show error
        }
        isRefreshing = false
    }

    private func unsubscribe() {
        // Delete downloads first
        DownloadManager.shared.deleteDownloads(for: podcast)
        modelContext.delete(podcast)
        dismiss()
    }

    private func prepareAndShare() async {
        isPreparingShare = true

        // If private feed without public URL, try to find it
        if podcast.isPrivateFeed && podcast.publicFeedURL == nil {
            await lookupPublicFeed()
            try? modelContext.save()
        }

        await MainActor.run {
            shareText = podcast.shareURL
            isPreparingShare = false
        }
    }

    private func lookupPublicFeed() async {
        let logger = AppLogger.feed
        logger.info("Looking up public feed for: \(podcast.title)")
        logger.info("Private feed URL: \(podcast.feedURL)")

        // Clean up the title - remove common private feed suffixes
        var cleanTitle = podcast.title

        // Remove "(private feed for email@example.com)" pattern
        if let range = cleanTitle.range(of: #"\s*\(private feed.*\)"#, options: [.regularExpression, .caseInsensitive]) {
            cleanTitle = String(cleanTitle[..<range.lowerBound])
        }

        // Remove "(Premium)" or similar suffixes
        if let range = cleanTitle.range(of: #"\s*\((premium|subscriber|member|patron).*\)"#, options: [.regularExpression, .caseInsensitive]) {
            cleanTitle = String(cleanTitle[..<range.lowerBound])
        }

        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Clean title for search: \(cleanTitle)")

        // Try progressively shorter search queries until we find good matches
        // This handles cases like "If Books Could Kill Mile High Club" where "Mile High Club" is a tier name
        var searchQueries = [cleanTitle]
        let words = cleanTitle.split(separator: " ").map(String.init)
        if words.count > 3 {
            // Try removing last 1, 2, 3 words
            for dropCount in 1...min(3, words.count - 2) {
                let shortened = words.dropLast(dropCount).joined(separator: " ")
                if shortened.count >= 3 {
                    searchQueries.append(shortened)
                }
            }
        }

        for searchQuery in searchQueries {
            logger.info("Trying search query: \(searchQuery)")

            do {
                let results = try await PodcastLookupService.shared.searchPodcasts(query: searchQuery)
                logger.info("Found \(results.count) search results")

                if results.isEmpty { continue }

                // Try to find best match using word overlap
                let titleWords = Set(searchQuery.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
                logger.info("Title words: \(titleWords)")

                var bestMatch: (result: PodcastSearchResult, score: Int)?

                for result in results {
                    let resultWords = Set(result.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
                    let overlap = titleWords.intersection(resultWords).count
                    let score = overlap * 2 - abs(titleWords.count - resultWords.count)

                    logger.info("Result: '\(result.title)' - overlap: \(overlap), score: \(score)")

                    if result.feedURL != nil && score > 0 {
                        if bestMatch == nil || score > bestMatch!.score {
                            bestMatch = (result, score)
                        }
                    }
                }

                if let match = bestMatch, match.result.feedURL != nil {
                    logger.info("Best match: '\(match.result.title)' with score \(match.score)")
                    let appleURL = "https://podcasts.apple.com/podcast/id\(match.result.id)"
                    logger.info("Setting public URL: \(appleURL)")
                    await MainActor.run {
                        podcast.publicFeedURL = appleURL
                    }
                    return
                }
            } catch {
                logger.error("Search failed: \(error.localizedDescription)")
            }
        }

        logger.warning("No matching public feed found after trying all queries")
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Filter Toggle

private struct FilterToggle: View {
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

// MARK: - Podcast Header

private struct PodcastHeaderView: View {
    let podcast: Podcast
    let folders: [Folder]
    let onFolderTap: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            CachedAsyncImage(url: URL(string: podcast.artworkURL ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.2))
                    .overlay {
                        Image(systemName: "mic")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 4)

            VStack(spacing: 4) {
                Text(podcast.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                if let author = podcast.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Folder badges - tappable
            if !folders.isEmpty {
                Button {
                    onFolderTap()
                } label: {
                    HStack(spacing: 8) {
                        ForEach(folders) { folder in
                            HStack(spacing: 4) {
                                Image(systemName: "folder.fill")
                                    .font(.caption2)
                                Text(folder.name)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(folderColor(folder).opacity(0.15))
                            .foregroundStyle(folderColor(folder))
                            .clipShape(Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            if let description = podcast.podcastDescription, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private func folderColor(_ folder: Folder) -> Color {
        if let hex = folder.colorHex {
            return Color(hex: hex) ?? .accentColor
        }
        return .accentColor
    }
}

#Preview {
    NavigationStack {
        PodcastDetailView(podcast: Podcast(
            feedURL: "https://example.com/feed.xml",
            title: "Sample Podcast",
            author: "John Doe"
        ))
    }
    .modelContainer(for: Podcast.self, inMemory: true)
}
