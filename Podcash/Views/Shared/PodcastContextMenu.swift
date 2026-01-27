import SwiftUI
import SwiftData

struct PodcastContextMenu: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Folder.sortOrder) private var allFolders: [Folder]

    let podcast: Podcast
    var onRefresh: (() async -> Void)?
    var onUnsubscribe: (() -> Void)?
    var onShowFolderPicker: (() -> Void)?
    var onCreateFolder: ((Podcast) -> Void)?

    @State private var isRefreshing = false

    var body: some View {
        // Share (only if podcast can be shared)
        if podcast.canShare {
            ShareLink(item: podcast.shareURL) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }

        // Add to Folder
        if let onShowFolderPicker {
            Button {
                onShowFolderPicker()
            } label: {
                Label("Add to Folder", systemImage: "folder.badge.plus")
            }
        } else {
            folderMenu
        }

        Divider()

        // Mark All as Played
        Button {
            markAllAsPlayed()
        } label: {
            Label("Mark All as Played", systemImage: "checkmark.circle")
        }

        // Mark All as Unplayed
        Button {
            markAllAsUnplayed()
        } label: {
            Label("Mark All as Unplayed", systemImage: "circle")
        }

        Divider()

        // Refresh
        Button {
            Task {
                await refreshPodcast()
            }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }

        // Auto-Download Toggle
        Button {
            podcast.autoDownloadNewEpisodes.toggle()
            try? modelContext.save()
        } label: {
            Label(
                podcast.autoDownloadNewEpisodes ? "Disable Auto-Download" : "Enable Auto-Download",
                systemImage: podcast.autoDownloadNewEpisodes ? "arrow.down.circle.fill" : "arrow.down.circle"
            )
        }

        Divider()

        // Download Latest
        Menu {
            Button {
                downloadLatest(count: 1)
            } label: {
                Text("Latest Episode")
            }

            Button {
                downloadLatest(count: 3)
            } label: {
                Text("Latest 3 Episodes")
            }

            Button {
                downloadLatest(count: 5)
            } label: {
                Text("Latest 5 Episodes")
            }

            Button {
                downloadLatest(count: 10)
            } label: {
                Text("Latest 10 Episodes")
            }
        } label: {
            Label("Download Episodes", systemImage: "arrow.down.circle")
        }

        // Delete All Downloads
        if hasDownloads {
            Button(role: .destructive) {
                deleteAllDownloads()
            } label: {
                Label("Delete All Downloads", systemImage: "trash")
            }
        }

        Divider()

        // Unsubscribe
        Button(role: .destructive) {
            onUnsubscribe?()
        } label: {
            Label("Unsubscribe", systemImage: "minus.circle")
        }
    }

    // MARK: - Folder Menu

    @ViewBuilder
    private var folderMenu: some View {
        Menu {
            // Existing folders
            ForEach(allFolders) { folder in
                Button {
                    togglePodcastInFolder(folder)
                } label: {
                    if isInFolder(folder) {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }

            if !allFolders.isEmpty {
                Divider()
            }

            // Create new folder option
            if let onCreateFolder {
                Button {
                    onCreateFolder(podcast)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
        } label: {
            Label("Add to Folder", systemImage: "folder.badge.plus")
        }
    }

    // MARK: - Computed Properties

    private var hasDownloads: Bool {
        podcast.episodes.contains { $0.localFilePath != nil }
    }

    private var sortedEpisodes: [Episode] {
        podcast.episodes.sorted { e1, e2 in
            (e1.publishedDate ?? .distantPast) > (e2.publishedDate ?? .distantPast)
        }
    }

    // MARK: - Actions

    private func isInFolder(_ folder: Folder) -> Bool {
        folder.podcasts.contains { $0.feedURL == podcast.feedURL }
    }

    private func togglePodcastInFolder(_ folder: Folder) {
        if let index = folder.podcasts.firstIndex(where: { $0.feedURL == podcast.feedURL }) {
            folder.podcasts.remove(at: index)
        } else {
            folder.podcasts.append(podcast)
        }
        try? modelContext.save()
    }

    private func markAllAsPlayed() {
        for episode in podcast.episodes {
            episode.isPlayed = true
        }
        try? modelContext.save()
    }

    private func markAllAsUnplayed() {
        for episode in podcast.episodes {
            episode.isPlayed = false
            episode.playbackPosition = 0
        }
        try? modelContext.save()
    }

    private func refreshPodcast() async {
        isRefreshing = true
        if let onRefresh {
            await onRefresh()
        } else {
            _ = try? await FeedService.shared.refreshPodcast(podcast, context: modelContext)
        }
        isRefreshing = false
    }

    private func downloadLatest(count: Int) {
        let latestEpisodes = Array(sortedEpisodes.prefix(count))
        for episode in latestEpisodes {
            if episode.localFilePath == nil && episode.downloadProgress == nil {
                // Use direct download (bypass network check for explicit user action)
                // Or check network preference - let's respect the setting
                let result = DownloadManager.shared.checkDownloadAllowed(episode, isAutoDownload: false, context: modelContext)
                if case .started = result {
                    DownloadManager.shared.download(episode)
                }
                // Note: if blocked or needs confirmation, we skip silently for bulk download
                // A more sophisticated approach would queue them or show a single confirmation
            }
        }
    }

    private func deleteAllDownloads() {
        DownloadManager.shared.deleteDownloads(for: podcast)
    }
}
