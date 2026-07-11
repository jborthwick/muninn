import SwiftUI
import SwiftData

struct PlaylistPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let episodes: [Episode]
    let allPlaylists: [Playlist]

    @State private var showingNewPlaylist = false

    var body: some View {
        NavigationStack {
            List {
                if allPlaylists.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Playlists",
                            systemImage: "music.note.list",
                            description: Text("Create a playlist to save episodes")
                        )
                    }
                } else {
                    Section {
                        ForEach(allPlaylists) { playlist in
                            Button {
                                addToPlaylist(playlist)
                            } label: {
                                HStack {
                                    Image(systemName: "music.note.list")
                                        .foregroundStyle(playlistColor(playlist))

                                    Text(playlist.name)
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    if allEpisodesInPlaylist(playlist) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    } else if anyEpisodeInPlaylist(playlist) {
                                        Text("\(episodeCount(in: playlist))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("Tap a playlist to add selected episodes")
                    }
                }

                Section {
                    Button {
                        showingNewPlaylist = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text("New Playlist")
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingNewPlaylist) {
                EditPlaylistView(playlist: nil)
            }
        }
    }

    private func addToPlaylist(_ playlist: Playlist) {
        PlaylistManager.shared.addEpisodes(episodes, to: playlist)
        dismiss()
    }

    private func allEpisodesInPlaylist(_ playlist: Playlist) -> Bool {
        !episodes.isEmpty && episodes.allSatisfy { PlaylistManager.shared.isInPlaylist($0, playlist: playlist) }
    }

    private func anyEpisodeInPlaylist(_ playlist: Playlist) -> Bool {
        episodes.contains { PlaylistManager.shared.isInPlaylist($0, playlist: playlist) }
    }

    private func episodeCount(in playlist: Playlist) -> Int {
        episodes.filter { PlaylistManager.shared.isInPlaylist($0, playlist: playlist) }.count
    }

    private func playlistColor(_ playlist: Playlist) -> Color {
        if let hex = playlist.colorHex {
            return Color(hex: hex) ?? .accentColor
        }
        return .accentColor
    }
}

#Preview {
    PlaylistPickerView(episodes: [], allPlaylists: [])
        .modelContainer(for: [Playlist.self, Episode.self], inMemory: true)
}
