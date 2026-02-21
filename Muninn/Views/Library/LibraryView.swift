import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.miniPlayerVisible) private var miniPlayerVisible
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]
    @Query(sort: \Folder.sortOrder) private var folders: [Folder]

    @State private var showingAddPodcast = false
    @State private var showingAddFolder = false
    @State private var folderToEdit: Folder?
    @State private var podcastToUnsubscribe: Podcast?
    @State private var podcastForNewFolder: Podcast?

    private var refreshManager: RefreshManager { RefreshManager.shared }

    var body: some View {
        NavigationStack {
            Group {
                if podcasts.isEmpty && folders.isEmpty {
                    ContentUnavailableView(
                        "No Podcasts",
                        systemImage: "mic",
                        description: Text("Add a podcast to get started")
                    )
                } else {
                    List {
                        // Virtual folders section (only when user has folders)
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

                        // Folders section
                        if !folders.isEmpty {
                            Section("Folders") {
                                ForEach(folders) { folder in
                                    NavigationLink(value: folder) {
                                        FolderRowView(folder: folder)
                                    }
                                    .contextMenu {
                                        Button {
                                            folderToEdit = folder
                                        } label: {
                                            Label("Edit Folder", systemImage: "pencil")
                                        }

                                        Button(role: .destructive) {
                                            modelContext.delete(folder)
                                        } label: {
                                            Label("Delete Folder", systemImage: "trash")
                                        }
                                    }
                                }
                                .onDelete(perform: deleteFolders)
                            }
                        }

                        // Podcasts section
                        Section(folders.isEmpty ? "" : "All Podcasts") {
                            ForEach(podcasts) { podcast in
                                NavigationLink(value: podcast) {
                                    PodcastRowView(podcast: podcast)
                                }
                                .contextMenu {
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
                            }
                            .onDelete(perform: deletePodcasts)
                        }
                    }
                    .listStyle(.plain)
                    .contentMargins(.bottom, miniPlayerVisible ? 60 : 0, for: .scrollContent)
                    .refreshable {
                        // Trigger background refresh and return immediately
                        refreshManager.refreshAllPodcasts(context: modelContext)
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: Podcast.self) { podcast in
                PodcastDetailView(podcast: podcast)
            }
            .navigationDestination(for: Folder.self) { folder in
                FolderDetailView(folder: folder)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingAddPodcast = true
                        } label: {
                            Label("Add Podcast", systemImage: "plus")
                        }

                        Button {
                            showingAddFolder = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
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
            .sheet(item: $folderToEdit) { folder in
                EditFolderView(folder: folder)
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
                        DownloadManager.shared.deleteDownloads(for: podcast)
                        modelContext.delete(podcast)
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

    private func deletePodcasts(at offsets: IndexSet) {
        for index in offsets {
            let podcast = podcasts[index]
            // Delete downloads first
            DownloadManager.shared.deleteDownloads(for: podcast)
            modelContext.delete(podcast)
        }
    }

    private func deleteFolders(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(folders[index])
        }
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
