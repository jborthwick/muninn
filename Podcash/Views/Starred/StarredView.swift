import SwiftUI
import SwiftData

struct StarredView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var allEpisodes: [Episode]

    private var networkMonitor: NetworkMonitor { NetworkMonitor.shared }

    @State private var sortNewestFirst = true
    @State private var showDownloadedOnly = false

    private var starredEpisodes: [Episode] {
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
                                ForEach(starredEpisodes) { episode in
                                    StarredEpisodeRow(episode: episode)
                                        .onTapGesture {
                                            playEpisode(episode)
                                        }
                                }
                            }
                        } header: {
                            Text("\(starredEpisodes.count) Episodes")
                        }
                    }
                }
            }
            .navigationTitle("Starred")
            .onAppear {
                // Auto-filter to downloaded when offline
                if !networkMonitor.isConnected {
                    showDownloadedOnly = true
                }
            }
        }
    }

    private func playEpisode(_ episode: Episode) {
        // Check if offline and not downloaded
        if !networkMonitor.isConnected && episode.localFilePath == nil {
            return
        }

        // Auto-download when playing
        if episode.localFilePath == nil {
            DownloadManager.shared.download(episode)
        }

        AudioPlayerManager.shared.play(episode)
    }
}

// MARK: - Starred Episode Row

private struct StarredEpisodeRow: View {
    let episode: Episode

    var body: some View {
        HStack(spacing: 12) {
            // Podcast artwork
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

                HStack(spacing: 8) {
                    if let podcast = episode.podcast {
                        Text(podcast.title)
                    }
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
                // Star button (always filled since we're in starred view)
                Button {
                    episode.isStarred.toggle()
                } label: {
                    Image(systemName: "star.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)
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
