import SwiftUI

struct MiniPlayerView: View {
    var playerManager = AudioPlayerManager.shared
    @Binding var showNowPlaying: Bool

    var body: some View {
        if let episode = playerManager.currentEpisode {
            VStack(spacing: 0) {
                // Progress bar
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * progress)
                }
                .frame(height: 2)
                .background(Color.secondary.opacity(0.2))

                // Content
                HStack(spacing: 12) {
                    // Artwork
                    CachedAsyncImage(url: URL(string: episode.displayArtworkURL ?? "")) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.2))
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    // Title and podcast
                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        if let podcast = episode.podcast {
                            Text(podcast.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Play/Pause button
                    Button {
                        playerManager.togglePlayPause()
                    } label: {
                        Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }

                    // Forward button
                    Button {
                        playerManager.skipForward()
                    } label: {
                        Image(systemName: "goforward.30")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .contextMenu {
                        Button {
                            episode.isPlayed = true
                            episode.playbackPosition = 0
                            playerManager.stop()
                        } label: {
                            Label("Mark as Played", systemImage: "checkmark.circle")
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
            .onTapGesture {
                showNowPlaying = true
            }
        }
    }

    private var progress: Double {
        guard playerManager.duration > 0 else { return 0 }
        return playerManager.currentTime / playerManager.duration
    }
}

#Preview {
    MiniPlayerView(showNowPlaying: .constant(false))
}
