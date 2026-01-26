import SwiftUI
import SwiftData

struct PodcastDetailView: View {
    @Environment(\.modelContext) private var modelContext
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
                    ForEach(filteredEpisodes) { episode in
                        EpisodeRowView(episode: episode)
                            .onTapGesture {
                                playEpisode(episode)
                            }
                            .contextMenu {
                                episodeContextMenu(for: episode)
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
                }
            } header: {
                Text("\(filteredEpisodes.count) Episodes")
            }
        }
        .listStyle(.plain)
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refreshPodcast()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 16) {
                    // Share button
                    ShareLink(item: podcastShareText) {
                        Image(systemName: "square.and.arrow.up")
                    }

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
        .onAppear {
            // Auto-filter to downloaded when offline
            if !networkMonitor.isConnected {
                showDownloadedOnly = true
            }
        }
    }

    private var filteredEpisodes: [Episode] {
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

    @ViewBuilder
    private func episodeContextMenu(for episode: Episode) -> some View {
        Button {
            playEpisode(episode)
        } label: {
            Label("Play", systemImage: "play")
        }

        Button {
            QueueManager.shared.playNext(episode)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            QueueManager.shared.addToQueue(episode)
        } label: {
            Label("Add to Queue", systemImage: "text.badge.plus")
        }

        Divider()

        Button {
            toggleStar(episode)
        } label: {
            Label(
                episode.isStarred ? "Unstar" : "Star",
                systemImage: episode.isStarred ? "star.slash" : "star"
            )
        }

        Divider()

        if episode.localFilePath != nil {
            Button(role: .destructive) {
                DownloadManager.shared.deleteDownload(episode)
            } label: {
                Label("Delete Download", systemImage: "trash")
            }
        } else if episode.downloadProgress != nil {
            Button {
                DownloadManager.shared.cancelDownload(episode)
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        } else {
            Button {
                DownloadManager.shared.download(episode)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }

        Divider()

        Button {
            episode.isPlayed.toggle()
        } label: {
            Label(
                episode.isPlayed ? "Mark Unplayed" : "Mark Played",
                systemImage: episode.isPlayed ? "circle" : "checkmark.circle"
            )
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

    private var podcastShareText: String {
        var text = "🎧 \(podcast.title)"
        if let author = podcast.author {
            text += " by \(author)"
        }
        text += "\n\n\(podcast.feedURL)"
        return text
    }
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
