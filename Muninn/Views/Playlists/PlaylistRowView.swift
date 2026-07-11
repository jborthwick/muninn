import SwiftUI

struct PlaylistRowView: View {
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.title2)
                .foregroundStyle(playlistColor)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.headline)

                Text("\(playlist.items.count) episode\(playlist.items.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var playlistColor: Color {
        if let hex = playlist.colorHex {
            return Color(hex: hex) ?? .accentColor
        }
        return .accentColor
    }
}

#Preview {
    PlaylistRowView(playlist: Playlist(name: "Campaign 3"))
}
