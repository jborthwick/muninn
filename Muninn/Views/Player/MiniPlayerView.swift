import SwiftUI

struct MiniPlayerView: View {
    var playerManager = AudioPlayerManager.shared
    @Binding var showNowPlaying: Bool

    var body: some View {
        if let episode = playerManager.currentEpisode {
            HStack(spacing: 12) {
                // Artwork
                CachedAsyncImage(url: URL(string: episode.displayArtworkURL ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle()
                        .fill(Color.secondary.opacity(0.2))
                        .overlay {
                            Image(systemName: "mic")
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())

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

                Spacer(minLength: 8)

                // Play/Pause button
                Button {
                    playerManager.togglePlayPause()
                } label: {
                    Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 40, height: 40)
                }

                // Forward button
                Button {
                    playerManager.skipForward()
                } label: {
                    Image(systemName: skipForwardIcon)
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .contextMenu {
                    Button {
                        playerManager.skipBackward()
                    } label: {
                        Label("Skip Backward", systemImage: skipBackwardIcon)
                    }
                    
                    Button {
                        playerManager.markPlayedAndAdvance()
                    } label: {
                        Label("Mark as Played", systemImage: "checkmark.circle")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .modifier(GlassBackgroundModifier())
            .overlay(alignment: .bottom) {
                // Progress indicator at bottom — inset enough to stay inside the pill's curved ends
                GeometryReader { geometry in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * progress, height: 3)
                }
                .frame(height: 3)
                .padding(.horizontal, 28)
                .padding(.bottom, 4)
            }
            .onTapGesture {
                showNowPlaying = true
            }
            .padding(.horizontal, 16)
        }
    }

    private var progress: Double {
        guard playerManager.duration > 0 else { return 0 }
        return playerManager.currentTime / playerManager.duration
    }

    private var skipForwardIcon: String {
        let interval = Int(playerManager.skipForwardInterval)
        let validIntervals = [5, 10, 15, 30, 45, 60, 75, 90]
        if validIntervals.contains(interval) {
            return "goforward.\(interval)"
        }
        return "goforward.30"
    }

    private var skipBackwardIcon: String {
        let interval = Int(playerManager.skipBackwardInterval)
        let validIntervals = [5, 10, 15, 30, 45, 60, 75, 90]
        if validIntervals.contains(interval) {
            return "gobackward.\(interval)"
        }
        return "gobackward.15"
    }
}

#Preview {
    MiniPlayerView(showNowPlaying: .constant(false))
}
// MARK: - Glass Background Modifier

private struct GlassBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

