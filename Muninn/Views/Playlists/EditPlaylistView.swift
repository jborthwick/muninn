import SwiftUI
import SwiftData

struct EditPlaylistView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let playlist: Playlist?

    @State private var name: String = ""
    @State private var selectedColor: String = "007AFF"
    @FocusState private var isNameFocused: Bool

    private let colorOptions = [
        "007AFF",
        "34C759",
        "FF9500",
        "FF3B30",
        "AF52DE",
        "FF2D55",
        "5856D6",
        "00C7BE",
    ]

    private var isEditing: Bool { playlist != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist Name") {
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
            }
            .navigationTitle(isEditing ? "Edit Playlist" : "New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") {
                        savePlaylist()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let playlist {
                    name = playlist.name
                    selectedColor = playlist.colorHex ?? "007AFF"
                } else {
                    isNameFocused = true
                }
            }
        }
    }

    private func savePlaylist() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let playlist {
            playlist.name = trimmedName
            playlist.colorHex = selectedColor
            try? modelContext.save()
        } else {
            _ = PlaylistManager.shared.createPlaylist(name: trimmedName, colorHex: selectedColor)
        }

        dismiss()
    }
}

#Preview {
    EditPlaylistView(playlist: nil)
        .modelContainer(for: [Playlist.self], inMemory: true)
}
