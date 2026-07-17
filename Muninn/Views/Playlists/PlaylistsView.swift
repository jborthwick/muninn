import SwiftUI
import SwiftData

struct PlaylistsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]
    @Query(sort: \Playlist.sortOrder) private var playlists: [Playlist]

    @State private var showingAddPlaylist = false
    @State private var playlistToEdit: Playlist?

    var body: some View {
        NavigationStack {
            List {
                shortcutsSection

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
            .listStyle(.plain)
            .navigationTitle("Playlists")
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddPlaylist = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddPlaylist) {
                EditPlaylistView(playlist: nil)
            }
            .sheet(item: $playlistToEdit) { playlist in
                EditPlaylistView(playlist: playlist)
            }
        }
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        Section {
            NavigationLink {
                AllEpisodesView()
            } label: {
                Label("All Episodes", systemImage: "list.bullet")
            }

            if !folders.isEmpty {
                NavigationLink {
                    AllEpisodesView(showUnsortedOnly: true)
                } label: {
                    Label("Unsorted", systemImage: "tray")
                }
            }

            NavigationLink {
                StarredView()
            } label: {
                Label("Starred", systemImage: "star")
            }

            NavigationLink {
                DownloadsView()
            } label: {
                Label("Downloads", systemImage: "arrow.down.circle")
            }
        }
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

    private func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            PlaylistManager.shared.deletePlaylist(playlists[index])
        }
    }
}

#Preview {
    PlaylistsView()
        .modelContainer(for: [Playlist.self, Folder.self], inMemory: true)
}
