import SwiftUI
import SwiftData

struct PlaylistDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var playlist: Playlist

    @State private var showEditSheet = false
    @State private var showClearConfirmation = false
    @State private var selectedEpisode: Episode?
    @State private var showCellularConfirmation = false
    @State private var episodePendingDownload: Episode?
    @State private var showBatchCellularConfirmation = false
    @State private var episodesPendingBatchDownload: [Episode] = []

    @State private var searchText = ""
    @State private var sortMode: PlaylistSortMode = .playlist
    @State private var showDownloadedOnly = false
    @State private var showUnplayedOnly = false
    @State private var isEditing = false
    @State private var editMode: EditMode = .inactive

    @State private var isSelecting = false
    @State private var selectedEpisodeGUIDs: Set<String> = []
    @State private var rangeAnchorGUID: String?

    private var playlistOrderedItems: [PlaylistItem] {
        playlist.items
            .sorted { $0.sortOrder < $1.sortOrder }
            .filter { $0.episode != nil }
    }

    private var browseDisplayedItems: [PlaylistItem] {
        PlaylistDetailFilters.items(
            from: playlistOrderedItems,
            searchText: searchText,
            sortMode: sortMode,
            downloadedOnly: showDownloadedOnly,
            unplayedOnly: showUnplayedOnly
        )
    }

    private var displayedItems: [PlaylistItem] {
        if isEditing { return playlistOrderedItems }
        return browseDisplayedItems
    }

    private var selectedEpisodes: [Episode] {
        guard !selectedEpisodeGUIDs.isEmpty else { return [] }
        return browseDisplayedItems.compactMap(\.episode).filter { selectedEpisodeGUIDs.contains($0.guid) }
    }

    private var hasAnyEpisodes: Bool { !playlistOrderedItems.isEmpty }

    var body: some View {
        Group {
            if !hasAnyEpisodes {
                ContentUnavailableView(
                    "No Episodes",
                    systemImage: "music.note.list",
                    description: Text("Add episodes from a podcast or episode menu")
                )
            } else {
                List {
                    if !isEditing && !isSelecting {
                        sortFilterSection
                    }

                    episodesSection
                }
                .listStyle(.plain)
                .environment(\.editMode, $editMode)
            }
        }
        .navigationTitle(playlist.name)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionActionBar
            }
        }
        .preference(key: EpisodeSelectionActivePreference.self, value: isSelecting)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSelecting)
        .sheet(isPresented: $showEditSheet) {
            EditPlaylistView(playlist: playlist)
        }
        .sheet(item: $selectedEpisode) { episode in
            EpisodeDetailView(episode: episode)
        }
        .alert("Download on Cellular?", isPresented: $showCellularConfirmation) {
            Button("Download") {
                if let episode = episodePendingDownload {
                    DownloadManager.shared.download(episode, userInitiated: modelContext)
                }
                episodePendingDownload = nil
            }
            Button("Cancel", role: .cancel) {
                episodePendingDownload = nil
            }
        } message: {
            Text("You're on cellular data. Download anyway?")
        }
        .alert("Download on Cellular?", isPresented: $showBatchCellularConfirmation) {
            Button("Download") {
                for episode in episodesPendingBatchDownload {
                    DownloadManager.shared.download(episode, userInitiated: modelContext)
                }
                episodesPendingBatchDownload = []
            }
            Button("Cancel", role: .cancel) {
                episodesPendingBatchDownload = []
            }
        } message: {
            Text("You're on cellular data. Download \(episodesPendingBatchDownload.count) episode\(episodesPendingBatchDownload.count == 1 ? "" : "s") anyway?")
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

    // MARK: - Sections

    @ViewBuilder
    private var sortFilterSection: some View {
        Section {
            searchField

            HStack(spacing: 12) {
                Button {
                    sortMode.cycle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: sortMode.icon)
                        Text(sortMode.label)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                FilterToggleButton(
                    isOn: $showDownloadedOnly,
                    icon: "arrow.down.circle.fill",
                    activeColor: .green
                )

                FilterToggleButton(
                    isOn: $showUnplayedOnly,
                    icon: "circle",
                    activeColor: .accentColor
                )

                Spacer()
            }
        }
        .listSectionSeparator(.hidden, edges: .bottom)
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 15))
            TextField("Search episodes", text: $searchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color(.tertiaryLabel))
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var episodesSection: some View {
        Section {
            if displayedItems.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try adjusting search or filters")
                )
            } else {
                HStack {
                    Text("\(displayedItems.count) Episode\(displayedItems.count == 1 ? "" : "s")")
                    Spacer()
                    if isEditing {
                        Text("Drag to reorder")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                ForEach(displayedItems) { item in
                    if let episode = item.episode {
                        episodeRow(item: item, episode: episode)
                    }
                }
                .onMove(perform: isEditing ? moveItems : nil)
            }
        }
    }

    @ViewBuilder
    private func episodeRow(item: PlaylistItem, episode: Episode) -> some View {
        PlaylistEpisodeRow(
            episode: episode,
            isSelecting: isSelecting,
            isSelected: selectedEpisodeGUIDs.contains(episode.guid)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                toggleEpisodeSelection(episode)
                rangeAnchorGUID = episode.guid
            } else if !isEditing {
                selectedEpisode = episode
            }
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            if isSelecting {
                selectEpisodeRange(to: episode)
            }
        }
        .contextMenu {
            if !isEditing && !isSelecting {
                EpisodeContextMenu(
                    episode: episode,
                    onDownloadNeedsConfirmation: {
                        episodePendingDownload = episode
                        showCellularConfirmation = true
                    }
                )
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isEditing && !isSelecting {
                Button(role: .destructive) {
                    PlaylistManager.shared.removeItem(item)
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
            }
        }
        .listRowBackground(
            selectedEpisodeGUIDs.contains(episode.guid) && isSelecting
                ? Color.accentColor.opacity(0.08) : nil
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") {
                    exitSelectionMode()
                }
            }
        } else if hasAnyEpisodes {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    PlaylistManager.shared.play(playlist)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .disabled(isEditing)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Done" : "Edit") {
                    toggleEditMode()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                moreMenu
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showEditSheet = true
                } label: {
                    Label("Edit Playlist", systemImage: "pencil")
                }
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button {
                enterSelectionMode()
            } label: {
                Label("Select Episodes", systemImage: "checkmark.circle")
            }

            Divider()

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

            if hasAnyEpisodes {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Label("Clear Episodes", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    // MARK: - Actions

    private func toggleEditMode() {
        if isEditing {
            isEditing = false
            editMode = .inactive
        } else {
            exitSelectionMode()
            sortMode = .playlist
            searchText = ""
            showDownloadedOnly = false
            showUnplayedOnly = false
            isEditing = true
            editMode = .active
        }
    }

    private func enterSelectionMode() {
        if isEditing { toggleEditMode() }
        isSelecting = true
        selectedEpisodeGUIDs = []
        rangeAnchorGUID = nil
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedEpisodeGUIDs = []
        rangeAnchorGUID = nil
    }

    private func toggleEpisodeSelection(_ episode: Episode) {
        if selectedEpisodeGUIDs.contains(episode.guid) {
            selectedEpisodeGUIDs.remove(episode.guid)
        } else {
            selectedEpisodeGUIDs.insert(episode.guid)
        }
    }

    private func selectEpisodeRange(to episode: Episode) {
        let orderedGUIDs = browseDisplayedItems.compactMap { $0.episode?.guid }
        guard let endIndex = orderedGUIDs.firstIndex(of: episode.guid) else { return }

        if let anchorGUID = rangeAnchorGUID,
           let startIndex = orderedGUIDs.firstIndex(of: anchorGUID) {
            let low = min(startIndex, endIndex)
            let high = max(startIndex, endIndex)
            selectedEpisodeGUIDs = Set(orderedGUIDs[low...high])
        } else {
            selectedEpisodeGUIDs = [episode.guid]
        }

        rangeAnchorGUID = episode.guid
    }

    private func selectAll() {
        selectedEpisodeGUIDs = Set(browseDisplayedItems.compactMap { $0.episode?.guid })
    }

    private var selectionActionBar: some View {
        let totalCount = browseDisplayedItems.count
        let allSelected = totalCount > 0 && selectedEpisodeGUIDs.count == totalCount
        let hasSelection = !selectedEpisodeGUIDs.isEmpty
        let hasUndownloaded = selectedEpisodes.contains { $0.localFilePath == nil && $0.downloadProgress == nil }
        let hasDownloaded = selectedEpisodes.contains { $0.localFilePath != nil }

        return PlaylistSelectionActionBar(
            selectedCount: selectedEpisodeGUIDs.count,
            totalCount: totalCount,
            allSelected: allSelected,
            hasSelection: hasSelection,
            hasUndownloaded: hasUndownloaded,
            hasDownloaded: hasDownloaded,
            onToggleSelectAll: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    if allSelected { selectedEpisodeGUIDs = [] } else { selectAll() }
                }
            },
            onPlayNext: batchPlayNext,
            onAddToQueue: batchAddToQueue,
            onDownload: batchDownload,
            onDeleteDownloads: batchDeleteDownloads,
            onMarkPlayed: batchMarkPlayed,
            onStar: batchStar,
            onRemoveFromPlaylist: batchRemoveFromPlaylist
        )
    }

    private func batchPlayNext() {
        PlaylistDetailBatchActions.playNext(selectedEpisodes)
        exitSelectionMode()
    }

    private func batchAddToQueue() {
        PlaylistDetailBatchActions.addToQueue(selectedEpisodes)
        exitSelectionMode()
    }

    private func batchDownload() {
        let toConfirm = PlaylistDetailBatchActions.download(selectedEpisodes, context: modelContext)
        if !toConfirm.isEmpty {
            episodesPendingBatchDownload = toConfirm
            showBatchCellularConfirmation = true
        }
        exitSelectionMode()
    }

    private func batchDeleteDownloads() {
        PlaylistDetailBatchActions.deleteDownloads(selectedEpisodes, context: modelContext)
        exitSelectionMode()
    }

    private func batchMarkPlayed(_ played: Bool) {
        PlaylistDetailBatchActions.markPlayed(selectedEpisodes, played: played, context: modelContext)
        exitSelectionMode()
    }

    private func batchStar(_ starred: Bool) {
        PlaylistDetailBatchActions.setStarred(selectedEpisodes, starred: starred, context: modelContext)
        exitSelectionMode()
    }

    private func batchRemoveFromPlaylist() {
        PlaylistDetailBatchActions.removeFromPlaylist(selectedEpisodes, items: playlistOrderedItems)
        exitSelectionMode()
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        withTransaction(Transaction(animation: nil)) {
            PlaylistManager.shared.moveItems(playlistOrderedItems, from: source, to: destination)
        }
    }
}

#Preview {
    NavigationStack {
        PlaylistDetailView(playlist: Playlist(name: "Test"))
    }
    .modelContainer(for: [Playlist.self, PlaylistItem.self, Episode.self], inMemory: true)
}
