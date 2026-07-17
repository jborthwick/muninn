import SwiftUI

struct MiniPlayerView: View {
    var playerManager = AudioPlayerManager.shared
    @Binding var showNowPlaying: Bool
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool {
        placement == .inline
    }

    var body: some View {
        if let episode = playerManager.currentEpisode {
            HStack(spacing: isInline ? 8 : 12) {
                artwork(for: episode)

                VStack(alignment: .leading, spacing: isInline ? 4 : 6) {
                    Text(episode.title)
                        .font(isInline ? .footnote : .subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    progressBar
                }

                Spacer(minLength: isInline ? 4 : 8)

                Button {
                    playerManager.togglePlayPause()
                } label: {
                    Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(isInline ? .body : .title2)
                        .frame(width: isInline ? 32 : 40, height: isInline ? 32 : 40)
                }

                Button {
                    playerManager.skipForward()
                } label: {
                    Image(systemName: skipForwardIcon)
                        .font(isInline ? .subheadline : .title3)
                        .frame(width: isInline ? 32 : 40, height: isInline ? 32 : 40)
                }
                .contextMenu {
                    skipContextMenuItems
                }
            }
            .padding(.horizontal, isInline ? 12 : 16)
            .padding(.vertical, isInline ? 6 : 12)
            .contentShape(Rectangle())
            .onTapGesture {
                showNowPlaying = true
            }
        }
    }

    @ViewBuilder
    private func artwork(for episode: Episode) -> some View {
        let size: CGFloat = isInline ? 36 : 48
        CachedAsyncImage(url: URL(string: episode.displayArtworkURL ?? "")) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: isInline ? 8 : 10, style: .continuous)
                .fill(Color.secondary.opacity(0.2))
                .overlay {
                    Image(systemName: "mic")
                        .font(isInline ? .caption : .body)
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: isInline ? 8 : 10, style: .continuous))
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: max(0, geo.size.width * progress))
            }
        }
        .frame(height: isInline ? 3 : 4)
        .accessibilityLabel("Playback progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }

    @ViewBuilder
    private var skipContextMenuItems: some View {
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

    private var progress: Double {
        guard playerManager.duration > 0 else { return 0 }
        return min(max(playerManager.currentTime / playerManager.duration, 0), 1)
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

struct GlassBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: .capsule)
    }
}
