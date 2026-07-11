import SwiftUI
import SwiftData

struct PlaylistDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.miniPlayerVisible) private var miniPlayerVisible
    @Bindable var playlist: Playlist

    @State private var showEditSheet = false
    @State private var showClearConfirmation = false
    @State private var selectedEpisode: Episode?

    private var sortedItems: [PlaylistItem] {
        playlist.items.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        Group {
            if sortedItems.isEmpty {
                ContentUnavailableView(
                    "No Episodes",
                    systemImage: "music.note.list",
                    description: Text("Add episodes from a podcast or episode menu")
                )
            } else {
                List {
                    ForEach(sortedItems) { item in
                        if let episode = item.episode {
                            PlaylistEpisodeRow(episode: episode)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedEpisode = episode
                                }
                        }
                    }
                    .onMove(perform: moveItems)
                    .onDelete(perform: deleteItems)
                }
                .listStyle(.plain)
                .contentMargins(.bottom, miniPlayerVisible ? 60 : 0, for: .scrollContent)
                .environment(\.editMode, .constant(.active))
            }
        }
        .navigationTitle(playlist.name)
        .toolbar {
            if !sortedItems.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        PlaylistManager.shared.play(playlist)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                }

                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Button {
                            PlaylistManager.shared.addToQueue(playlist)
                        } label: {
                            Label("Add to Up Next", systemImage: "text.badge.plus")
                        }

                        Button {
                            showEditSheet = true
                        } label: {
                            Label("Edit Playlist", systemImage: "pencil")
                        }

                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            Label("Clear Episodes", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showEditSheet = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            EditPlaylistView(playlist: playlist)
        }
        .sheet(item: $selectedEpisode) { episode in
            EpisodeDetailView(episode: episode)
        }
        .confirmationDialog(
            "Clear Playlist?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Episodes", role: .destructive) {
                PlaylistManager.shared.clearPlaylist(playlist)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all episodes from \"\(playlist.name)\" but keeps the playlist.")
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            PlaylistManager.shared.removeItem(sortedItems[index])
        }
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        withTransaction(Transaction(animation: nil)) {
            PlaylistManager.shared.moveItems(sortedItems, from: source, to: destination)
        }
    }
}

// MARK: - Playlist Episode Row

private struct PlaylistEpisodeRow: View, Equatable {
    let episode: Episode

    static func == (lhs: PlaylistEpisodeRow, rhs: PlaylistEpisodeRow) -> Bool {
        lhs.episode.guid == rhs.episode.guid
            && lhs.episode.title == rhs.episode.title
            && lhs.episode.localFilePath == rhs.episode.localFilePath
            && lhs.episode.downloadProgress == rhs.episode.downloadProgress
            && lhs.episode.podcast?.feedURL == rhs.episode.podcast?.feedURL
    }

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: URL(string: episode.displayArtworkURL ?? "")) { image in
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

                HStack(spacing: 8) {
                    if let podcast = episode.podcast {
                        Text(podcast.title)
                    }
                    if let duration = episode.duration {
                        Text("•")
                        Text(duration.formattedDuration)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let progress = episode.downloadProgress {
                CircularProgressView(progress: progress)
                    .frame(width: 16, height: 16)
            } else if episode.localFilePath != nil {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }
}

#Preview {
    NavigationStack {
        PlaylistDetailView(playlist: Playlist(name: "Test"))
    }
    .modelContainer(for: [Playlist.self, PlaylistItem.self, Episode.self], inMemory: true)
}
