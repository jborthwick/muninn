import SwiftUI
import SwiftData

struct EditFolderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Podcast.title) private var allPodcasts: [Podcast]

    let folder: Folder?
    var initialPodcast: Podcast?

    @State private var name: String = ""
    @State private var selectedColor: String = "007AFF" // Default blue
    @State private var selectedPodcasts: Set<String> = [] // Feed URLs
    @State private var showManagePodcasts = false
    @State private var createdFolder: Folder?
    @State private var autoDownloadEnabled: Bool = false
    @FocusState private var isNameFocused: Bool

    private let colorOptions = [
        "007AFF", // Blue
        "34C759", // Green
        "FF9500", // Orange
        "FF3B30", // Red
        "AF52DE", // Purple
        "FF2D55", // Pink
        "5856D6", // Indigo
        "00C7BE", // Teal
    ]

    private var isEditing: Bool { folder != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Folder Name") {
                    TextField("Name", text: $name)
                        .focused($isNameFocused)
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                        ForEach(colorOptions, id: \.self) { hex in
                            Button {
                                selectedColor = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex) ?? .gray)
                                    .frame(width: 44, height: 44)
                                    .overlay {
                                        if selectedColor == hex {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.white)
                                                .fontWeight(.bold)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }

                // Auto-download section
                Section {
                    Toggle(isOn: $autoDownloadEnabled) {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.green)
                            Text("Auto-Download New Episodes")
                        }
                    }
                } footer: {
                    Text("Automatically download new episodes from podcasts in this folder")
                }

                // Show podcasts section for editing existing folders
                if isEditing, let folder = folder {
                    Section {
                        Button {
                            showManagePodcasts = true
                        } label: {
                            HStack {
                                Text("Podcasts in folder")
                                Spacer()
                                Text("\(folder.podcasts.count)")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Folder" : "New Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") {
                        saveFolder()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let folder = folder {
                    name = folder.name
                    selectedColor = folder.colorHex ?? "007AFF"
                    selectedPodcasts = Set(folder.podcasts.map { $0.feedURL })
                    autoDownloadEnabled = folder.autoDownloadNewEpisodes
                } else {
                    // Auto-focus name field for new folders
                    isNameFocused = true
                }
            }
            .sheet(isPresented: $showManagePodcasts, onDismiss: {
                // If we just created a new folder (not editing), dismiss the entire view
                if createdFolder != nil {
                    dismiss()
                }
            }) {
                if let folder = folder ?? createdFolder {
                    ManageFolderPodcastsSheet(folder: folder, allPodcasts: allPodcasts)
                }
            }
            .onChange(of: createdFolder) { _, newFolder in
                if newFolder != nil {
                    showManagePodcasts = true
                }
            }
        }
    }

    private func saveFolder() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let folder = folder {
            // Edit existing
            folder.name = trimmedName
            folder.colorHex = selectedColor
            folder.autoDownloadNewEpisodes = autoDownloadEnabled
            try? modelContext.save()
            dismiss()
        } else {
            // Create new - then show podcast picker
            let newFolder = Folder(name: trimmedName, colorHex: selectedColor)
            newFolder.autoDownloadNewEpisodes = autoDownloadEnabled
            // Add initial podcast if provided (from context menu)
            if let initialPodcast {
                newFolder.podcasts.append(initialPodcast)
            }
            modelContext.insert(newFolder)
            try? modelContext.save()
            createdFolder = newFolder
        }
    }
}

// MARK: - Manage Folder Podcasts Sheet

private struct ManageFolderPodcastsSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Bindable var folder: Folder
    let allPodcasts: [Podcast]

    var body: some View {
        NavigationStack {
            List {
                if allPodcasts.isEmpty {
                    ContentUnavailableView(
                        "No Podcasts",
                        systemImage: "mic",
                        description: Text("Add podcasts to your library first")
                    )
                } else {
                    Section {
                        ForEach(allPodcasts) { podcast in
                            Button {
                                togglePodcast(podcast)
                            } label: {
                                HStack {
                                    // Podcast artwork
                                    CachedAsyncImage(url: URL(string: podcast.artworkURL ?? "")) { image in
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.secondary.opacity(0.2))
                                    }
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                    Text(podcast.title)
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    if isInFolder(podcast) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("Tap to add or remove podcasts from this folder")
                    }
                }
            }
            .navigationTitle("Add Podcasts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func isInFolder(_ podcast: Podcast) -> Bool {
        folder.podcasts.contains { $0.feedURL == podcast.feedURL }
    }

    private func togglePodcast(_ podcast: Podcast) {
        if let index = folder.podcasts.firstIndex(where: { $0.feedURL == podcast.feedURL }) {
            folder.podcasts.remove(at: index)
        } else {
            folder.podcasts.append(podcast)
        }
        try? modelContext.save()
    }
}

#Preview {
    EditFolderView(folder: nil, initialPodcast: nil)
        .modelContainer(for: [Folder.self, Podcast.self], inMemory: true)
}
