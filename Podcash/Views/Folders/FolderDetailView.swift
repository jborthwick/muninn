import SwiftUI
import SwiftData

struct FolderDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Podcast.title) private var allPodcasts: [Podcast]
    @Bindable var folder: Folder

    private var networkMonitor: NetworkMonitor { NetworkMonitor.shared }

    @State private var viewMode: ViewMode = .episodes
    @State private var sortNewestFirst = true
    @State private var showStarredOnly = false
    @State private var showDownloadedOnly = false
    @State private var showManagePodcasts = false

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

    // Get all episodes paired with their podcast (to avoid relationship issues)
    private var allEpisodesWithPodcast: [(episode: Episode, podcast: Podcast)] {
        podcastsInFolder.flatMap { podcast in
            podcast.episodes.map { episode in (episode: episode, podcast: podcast) }
        }
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
            }
        }
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    showManagePodcasts = true
                }
            }
        }
        .sheet(isPresented: $showManagePodcasts) {
            ManageFolderPodcastsView(folder: folder, allPodcasts: allPodcasts)
        }
        .onAppear {
            if !networkMonitor.isConnected {
                showDownloadedOnly = true
            }
        }
    }

    // MARK: - Podcasts View

    @ViewBuilder
    private var podcastsView: some View {
        Section {
            ForEach(podcastsInFolder) { podcast in
                NavigationLink(value: podcast) {
                    PodcastRowView(podcast: podcast)
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
                ForEach(filteredEpisodes, id: \.episode.guid) { item in
                    FolderEpisodeRow(episode: item.episode, podcast: item.podcast)
                        .onTapGesture {
                            playEpisode(item.episode)
                        }
                        .contextMenu {
                            EpisodeContextMenu(episode: item.episode) {
                                playEpisode(item.episode)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                item.episode.isStarred.toggle()
                                if item.episode.isStarred && item.episode.localFilePath == nil {
                                    DownloadManager.shared.download(item.episode)
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

    private func removePodcastFromFolder(_ podcast: Podcast) {
        if let index = folder.podcasts.firstIndex(where: { $0.feedURL == podcast.feedURL }) {
            folder.podcasts.remove(at: index)
            try? modelContext.save()
        }
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
    let episode: Episode
    let podcast: Podcast  // Explicitly passed to avoid relationship issues

    var body: some View {
        HStack(spacing: 12) {
            // Podcast artwork - use explicitly passed podcast
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

                HStack(spacing: 8) {
                    Text(podcast.title)
                        .lineLimit(1)
                    if let date = episode.publishedDate {
                        Text("•")
                        Text(date.relativeFormatted)
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
                        DownloadManager.shared.download(episode)
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
                        DownloadManager.shared.download(episode)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .contentShape(Rectangle())
        .opacity(episode.isPlayed ? 0.7 : 1.0)
    }
}

#Preview {
    let folder = Folder(name: "News", colorHex: "FF3B30")
    return NavigationStack {
        FolderDetailView(folder: folder)
    }
    .modelContainer(for: [Folder.self, Podcast.self], inMemory: true)
}
