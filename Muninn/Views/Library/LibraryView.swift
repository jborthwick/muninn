import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.miniPlayerVisible) private var miniPlayerVisible
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]
    @Query(sort: \Playlist.sortOrder) private var playlists: [Playlist]

    @State private var showingAddPodcast = false
    @State private var showingAddFolder = false
    @State private var showingAddPlaylist = false
    @State private var showingOPMLPicker = false
    @State private var opmlImportURL: URL?
    @State private var folderToEdit: Folder?
    @State private var playlistToEdit: Playlist?
    @State private var podcastToUnsubscribe: Podcast?
    @State private var podcastForNewFolder: Podcast?
    @AppStorage("library.useGridLayout") private var useGridLayout = false

    private var refreshManager: RefreshManager { RefreshManager.shared }

    var body: some View {
        NavigationStack {
            Group {
                if podcasts.isEmpty && folders.isEmpty && playlists.isEmpty {
                    ContentUnavailableView(
                        "No Podcasts",
                        systemImage: "mic",
                        description: Text("Add a podcast to get started")
                    )
                } else if useGridLayout {
                    gridContent
                } else {
                    listContent
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: Podcast.self) { podcast in
                PodcastDetailView(podcast: podcast)
            }
            .navigationDestination(for: Folder.self) { folder in
                FolderDetailView(folder: folder)
            }
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Section("View") {
                            Picker("Layout", selection: $useGridLayout) {
                                Label("List", systemImage: "list.bullet")
                                    .tag(false)
                                Label("Grid", systemImage: "square.grid.2x2")
                                    .tag(true)
                            }
                        }

                        Section {
                            Button {
                                showingAddPodcast = true
                            } label: {
                                Label("Add Podcast", systemImage: "plus")
                            }

                            Button {
                                showingOPMLPicker = true
                            } label: {
                                Label("Import from OPML", systemImage: "arrow.down.doc.fill")
                            }

                            Button {
                                showingAddFolder = true
                            } label: {
                                Label("New Folder", systemImage: "folder.badge.plus")
                            }

                            Button {
                                showingAddPlaylist = true
                            } label: {
                                Label("New Playlist", systemImage: "music.note.list")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $showingAddPodcast) {
                AddPodcastView()
            }
            .sheet(isPresented: $showingAddFolder, onDismiss: {
                podcastForNewFolder = nil
            }) {
                EditFolderView(folder: nil, initialPodcast: podcastForNewFolder)
            }
            .sheet(isPresented: $showingAddPlaylist) {
                EditPlaylistView(playlist: nil)
            }
            .fileImporter(
                isPresented: $showingOPMLPicker,
                allowedContentTypes: [.xml, .plainText],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    opmlImportURL = url
                }
            }
            .sheet(isPresented: Binding(
                get: { opmlImportURL != nil },
                set: { if !$0 { opmlImportURL = nil } }
            )) {
                if let url = opmlImportURL {
                    OPMLImportView(fileURL: url)
                }
            }
            .sheet(item: $folderToEdit) { folder in
                EditFolderView(folder: folder)
            }
            .sheet(item: $playlistToEdit) { playlist in
                EditPlaylistView(playlist: playlist)
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
                        removePodcast(podcast)
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
    }

    // MARK: - List Layout

    private var listContent: some View {
        List {
            libraryShortcutsSection
            foldersListSection
            playlistsListSection
            podcastsListSection
        }
        .listStyle(.plain)
        .contentMargins(.bottom, miniPlayerVisible ? 60 : 0, for: .scrollContent)
        .refreshable {
            await refreshManager.refreshAllPodcasts(context: modelContext)
        }
    }

    @ViewBuilder
    private var libraryShortcutsSection: some View {
        if !folders.isEmpty {
            Section {
                NavigationLink {
                    AllEpisodesView()
                } label: {
                    Label("All Episodes", systemImage: "list.bullet")
                }

                NavigationLink {
                    AllEpisodesView(showUnsortedOnly: true)
                } label: {
                    Label("Unsorted", systemImage: "tray")
                }
            }
        }
    }

    @ViewBuilder
    private var foldersListSection: some View {
        if !folders.isEmpty {
            Section("Folders") {
                ForEach(folders) { folder in
                    NavigationLink(value: folder) {
                        FolderRowView(folder: folder)
                    }
                    .contextMenu {
                        folderContextMenu(for: folder)
                    }
                }
                .onDelete(perform: deleteFolders)
            }
        }
    }

    @ViewBuilder
    private var playlistsListSection: some View {
        if !playlists.isEmpty {
            Section("Playlists") {
                ForEach(playlists) { playlist in
                    NavigationLink(value: playlist) {
                        PlaylistRowView(playlist: playlist)
                    }
                    .contextMenu {
                        playlistContextMenu(for: playlist)
                    }
                }
                .onDelete(perform: deletePlaylists)
            }
        }
    }

    @ViewBuilder
    private var podcastsListSection: some View {
        Section(folders.isEmpty ? "" : "All Podcasts") {
            ForEach(podcasts) { podcast in
                NavigationLink(value: podcast) {
                    PodcastRowView(podcast: podcast)
                }
                .contextMenu {
                    podcastContextMenu(for: podcast)
                }
            }
            .onDelete(perform: deletePodcasts)
        }
    }

    // MARK: - Grid Layout

    private var gridContent: some View {
        LibraryGridContent(
            podcasts: podcasts,
            folders: folders,
            playlists: playlists,
            miniPlayerBottomInset: miniPlayerVisible ? 60 : 16,
            onRefresh: {
                await refreshManager.refreshAllPodcasts(context: modelContext)
            },
            onUnsubscribe: { podcastToUnsubscribe = $0 },
            onCreateFolder: { podcast in
                podcastForNewFolder = podcast
                showingAddFolder = true
            },
            onEditFolder: { folderToEdit = $0 },
            onDeleteFolder: { folder in
                SyncService.shared.deleteFolder(folder, context: modelContext)
            },
            onEditPlaylist: { playlistToEdit = $0 },
            onDeletePlaylist: { playlist in
                PlaylistManager.shared.deletePlaylist(playlist)
            }
        )
    }

    @ViewBuilder
    private func podcastContextMenu(for podcast: Podcast) -> some View {
        PodcastContextMenu(
            podcast: podcast,
            onUnsubscribe: {
                podcastToUnsubscribe = podcast
            },
            onCreateFolder: { podcastToAdd in
                podcastForNewFolder = podcastToAdd
                showingAddFolder = true
            }
        )
    }

    @ViewBuilder
    private func playlistContextMenu(for playlist: Playlist) -> some View {
        Button {
            playlistToEdit = playlist
        } label: {
            Label("Edit Playlist", systemImage: "pencil")
        }

        Button(role: .destructive) {
            PlaylistManager.shared.deletePlaylist(playlist)
        } label: {
            Label("Delete Playlist", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func folderContextMenu(for folder: Folder) -> some View {
        Button {
            folderToEdit = folder
        } label: {
            Label("Edit Folder", systemImage: "pencil")
        }

        Button(role: .destructive) {
            SyncService.shared.deleteFolder(folder, context: modelContext)
        } label: {
            Label("Delete Folder", systemImage: "trash")
        }
    }

    private func removePodcast(_ podcast: Podcast) {
        // Stop playback if the current episode belongs to this podcast.
        if let current = AudioPlayerManager.shared.currentEpisode,
           current.podcast?.persistentModelID == podcast.persistentModelID {
            AudioPlayerManager.shared.stop()
        }

        // Delete local transcript files for every episode.
        for episode in podcast.episodes {
            if let url = episode.localTranscriptURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // Delete downloaded audio files.
        DownloadManager.shared.deleteDownloads(for: podcast)

        // Delete the podcast record — cascades to episodes and their queue items.
        modelContext.delete(podcast)
        try? modelContext.save()
    }

    private func deletePodcasts(at offsets: IndexSet) {
        for index in offsets {
            removePodcast(podcasts[index])
        }
    }

    private func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            PlaylistManager.shared.deletePlaylist(playlists[index])
        }
    }

    private func deleteFolders(at offsets: IndexSet) {
        let foldersToDelete = offsets.map { folders[$0] }
        SyncService.shared.deleteFolders(foldersToDelete, context: modelContext)
    }
}

// MARK: - Folder Row View

struct FolderRowView: View {
    let folder: Folder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(folderColor)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.headline)

                Text("\(folder.podcasts.count) podcast\(folder.podcasts.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var folderColor: Color {
        if let hex = folder.colorHex {
            return Color(hex: hex) ?? .accentColor
        }
        return .accentColor
    }
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
}

#Preview {
    LibraryView()
        .modelContainer(for: [Podcast.self, Folder.self], inMemory: true)
}
