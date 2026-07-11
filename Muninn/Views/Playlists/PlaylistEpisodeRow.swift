import SwiftUI

struct PlaylistEpisodeRow: View, Equatable {
    let episode: Episode
    var isSelecting: Bool = false
    var isSelected: Bool = false

    static func == (lhs: PlaylistEpisodeRow, rhs: PlaylistEpisodeRow) -> Bool {
        lhs.episode.guid == rhs.episode.guid
            && lhs.episode.title == rhs.episode.title
            && lhs.episode.localFilePath == rhs.episode.localFilePath
            && lhs.episode.downloadProgress == rhs.episode.downloadProgress
            && lhs.episode.isPlayed == rhs.episode.isPlayed
            && lhs.episode.podcast?.feedURL == rhs.episode.podcast?.feedURL
            && lhs.isSelecting == rhs.isSelecting
            && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: URL(string: episode.displayArtworkURL ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(episode.isPlayed ? .secondary : .primary)

                HStack(spacing: 8) {
                    if let podcast = episode.podcast {
                        Text(podcast.title)
                    }
                    if let duration = episode.duration {
                        Text("•")
                        Text(duration.formattedDuration)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 36, height: 36)
            } else if let progress = episode.downloadProgress {
                CircularProgressView(progress: progress)
                    .frame(width: 16, height: 16)
            } else if episode.localFilePath != nil {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }
}
