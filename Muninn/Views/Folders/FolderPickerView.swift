import SwiftUI
import SwiftData

struct FolderPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let podcast: Podcast
    let allFolders: [Folder]

    @State private var showingNewFolder = false

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
        }
    }

    private var isInAnyFolder: Bool {
        allFolders.contains { isInFolder($0) }
    }

    private func isInFolder(_ folder: Folder) -> Bool {
        folder.podcasts.contains { $0.feedURL == podcast.feedURL }
    }

    private func toggleFolder(_ folder: Folder) {
        if let index = folder.podcasts.firstIndex(where: { $0.feedURL == podcast.feedURL }) {
            folder.podcasts.remove(at: index)
        } else {
            folder.podcasts.append(podcast)
        }
        try? modelContext.save()
    }

    private func removeFromAllFolders() {
        for folder in allFolders {
            if let index = folder.podcasts.firstIndex(where: { $0.feedURL == podcast.feedURL }) {
                folder.podcasts.remove(at: index)
            }
        }
        try? modelContext.save()
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
