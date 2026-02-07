import SwiftUI
import SwiftData

struct FolderPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let podcast: Podcast
    let allFolders: [Folder]

    @State private var showingNewFolder = false
    
    // Cache for fast folder membership checks
    @State private var folderFeedURLs: [String: Set<String>] = [:]

    var body: some View {
        NavigationStack {
            List {
                if allFolders.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Folders",
                            systemImage: "folder",
                            description: Text("Create a folder to organize your podcasts")
                        )
                    }
                } else {
                    // No Folder option
                    Section {
                        Button {
                            removeFromAllFolders()
                        } label: {
                            HStack {
                                Image(systemName: "folder.badge.minus")
                                    .foregroundStyle(.secondary)

                                Text("No Folder")
                                    .foregroundStyle(.primary)

                                Spacer()

                                if !isInAnyFolder {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }

                    // Folder list
                    Section {
                        ForEach(Array(allFolders.enumerated()), id: \.element.id) { _, folder in
                            Button {
                                toggleFolder(folder)
                            } label: {
                                HStack {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(folderColor(folder))

                                    Text(folder.name)
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    if isInFolder(folder) {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("Tap to add or remove from folder")
                    }
                }

                Section {
                    Button {
                        showingNewFolder = true
                    } label: {
                        HStack {
                            Image(systemName: "folder.badge.plus")
                            Text("New Folder")
                        }
                    }
                }
            }
            .navigationTitle("Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingNewFolder) {
                EditFolderView(folder: nil)
            }
            .onAppear {
                updateFolderCache()
            }
        }
    }
    
    private func updateFolderCache() {
        folderFeedURLs = allFolders.reduce(into: [:]) { result, folder in
            result[folder.id.uuidString] = Set(folder.podcasts.map { $0.feedURL })
        }
    }

    private var isInAnyFolder: Bool {
        allFolders.contains { isInFolder($0) }
    }

    private func isInFolder(_ folder: Folder) -> Bool {
        // Use cached Set for O(1) lookup instead of O(n) search
        folderFeedURLs[folder.id.uuidString]?.contains(podcast.feedURL) ?? false
    }

    private func toggleFolder(_ folder: Folder) {
        // Optimistically update cache for immediate UI feedback
        var feedURLs = folderFeedURLs[folder.id.uuidString] ?? []
        if feedURLs.contains(podcast.feedURL) {
            feedURLs.remove(podcast.feedURL)
        } else {
            feedURLs.insert(podcast.feedURL)
        }
        folderFeedURLs[folder.id.uuidString] = feedURLs
        
        // Update the actual relationship
        if let index = folder.podcasts.firstIndex(where: { $0.feedURL == podcast.feedURL }) {
            folder.podcasts.remove(at: index)
        } else {
            folder.podcasts.append(podcast)
        }
        
        // Save asynchronously to avoid blocking the UI
        Task {
            try? modelContext.save()
        }
    }

    private func removeFromAllFolders() {
        // Optimistically update cache for all folders
        for folder in allFolders {
            if var feedURLs = folderFeedURLs[folder.id.uuidString] {
                feedURLs.remove(podcast.feedURL)
                folderFeedURLs[folder.id.uuidString] = feedURLs
            }
        }
        
        // Update the actual relationships
        for folder in allFolders {
            if let index = folder.podcasts.firstIndex(where: { $0.feedURL == podcast.feedURL }) {
                folder.podcasts.remove(at: index)
            }
        }
        
        // Save asynchronously to avoid blocking the UI
        Task {
            try? modelContext.save()
        }
    }

    private func folderColor(_ folder: Folder) -> Color {
        if let hex = folder.colorHex {
            return Color(hex: hex) ?? .accentColor
        }
        return .accentColor
    }
}

#Preview {
    let podcast = Podcast(feedURL: "https://example.com", title: "Test Podcast")
    return FolderPickerView(podcast: podcast, allFolders: [])
        .modelContainer(for: [Podcast.self, Folder.self], inMemory: true)
}
