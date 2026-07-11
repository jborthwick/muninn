import SwiftUI

struct LibraryGridContent: View {
    let podcasts: [Podcast]
    let folders: [Folder]
    let playlists: [Playlist]
    let miniPlayerBottomInset: CGFloat
    let onRefresh: () async -> Void
    let onUnsubscribe: (Podcast) -> Void
    let onCreateFolder: (Podcast) -> Void
    let onEditFolder: (Folder) -> Void
    let onDeleteFolder: (Folder) -> Void
    let onEditPlaylist: (Playlist) -> Void
    let onDeletePlaylist: (Playlist) -> Void

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !folders.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        NavigationLink {
                            AllEpisodesView()
                        } label: {
                            Label("All Episodes", systemImage: "list.bullet")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            AllEpisodesView(showUnsortedOnly: true)
                        } label: {
                            Label("Unsorted", systemImage: "tray")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Folders")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 16)

                        VStack(spacing: 0) {
                            ForEach(folders) { folder in
                                NavigationLink(value: folder) {
                                    FolderRowView(folder: folder)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        onEditFolder(folder)
                                    } label: {
                                        Label("Edit Folder", systemImage: "pencil")
                                    }

                                    Button(role: .destructive) {
                                        onDeleteFolder(folder)
                                    } label: {
                                        Label("Delete Folder", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if !playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Playlists")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 16)

                        VStack(spacing: 0) {
                            ForEach(playlists) { playlist in
                                NavigationLink(value: playlist) {
                                    PlaylistRowView(playlist: playlist)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        onEditPlaylist(playlist)
                                    } label: {
                                        Label("Edit Playlist", systemImage: "pencil")
                                    }

                                    Button(role: .destructive) {
                                        onDeletePlaylist(playlist)
                                    } label: {
                                        Label("Delete Playlist", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }

                if !podcasts.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        if !folders.isEmpty {
                            Text("All Podcasts")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 16)
                        }

                        LazyVGrid(columns: gridColumns, spacing: 20) {
                            ForEach(podcasts) { podcast in
                                NavigationLink(value: podcast) {
                                    PodcastGridItemView(podcast: podcast)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    PodcastContextMenu(
                                        podcast: podcast,
                                        onUnsubscribe: { onUnsubscribe(podcast) },
                                        onCreateFolder: onCreateFolder
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, miniPlayerBottomInset)
        }
        .refreshable {
            await onRefresh()
        }
    }
}
