import SwiftUI

/// Hero artwork + episode info that morphs between the full player layout and
/// the compact strip used above transcript/chapter panels.
struct NowPlayingEpisodeHeader: View {
    enum Panel: Equatable {
        case transcript
        case chapters
        case insight

        var dismissIcon: String {
            switch self {
            case .transcript: "quote.bubble.fill"
            case .chapters: "list.bullet.rectangle.fill"
            case .insight: "sparkles.rectangle.stack.fill"
            }
        }
    }

    let episode: Episode
    let panel: Panel?
    let onDismissPanel: () -> Void

    private var isCompact: Bool { panel != nil }

    private static let expandedArtSize: CGFloat = 280
    private static let compactArtSize: CGFloat = 60
    private static let compactScale: CGFloat = compactArtSize / expandedArtSize

    private var artSize: CGFloat { isCompact ? Self.compactArtSize : Self.expandedArtSize }
    private var artCornerRadius: CGFloat { isCompact ? 8 : 16 }

    var body: some View {
        VStack(spacing: 0) {
            if !isCompact {
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                if !isCompact {
                    Spacer(minLength: 0)
                }

                artworkTile

                if isCompact {
                    compactTitleColumn
                        .transition(.opacity.combined(with: .move(edge: .trailing)))

                    Spacer(minLength: 0)

                    if let panel {
                        Button(action: onDismissPanel) {
                            Image(systemName: panel.dismissIcon)
                                .font(.title2)
                                .foregroundStyle(.tint)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, isCompact ? 16 : 0)
            .padding(.top, isCompact ? 8 : 0)

            if !isCompact {
                expandedTitleColumn
                    .padding(.horizontal)
                    .padding(.top, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if !isCompact {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: isCompact ? 76 : nil, alignment: .top)
        .frame(maxHeight: isCompact ? 76 : .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.35), value: isCompact)
        .animation(.easeInOut(duration: 0.35), value: panel)
    }

    // MARK: - Artwork

    /// Renders at a fixed 280 pt and scales down for compact mode so the image
    /// never relayouts at an incorrect size after the transition finishes.
    private var artworkTile: some View {
        artworkView
            .frame(width: Self.expandedArtSize, height: Self.expandedArtSize)
            .scaleEffect(isCompact ? Self.compactScale : 1)
            .frame(width: artSize, height: artSize)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: artCornerRadius))
            .shadow(color: .black.opacity(isCompact ? 0 : 0.25), radius: isCompact ? 0 : 10)
    }

    private var artworkView: some View {
        CachedAsyncImage(url: URL(string: episode.displayArtworkURL ?? "")) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.secondary.opacity(0.2)
                .overlay {
                    Image(systemName: "mic")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: - Text

    private var expandedTitleColumn: some View {
        VStack(spacing: 4) {
            Text(episode.title)
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)

            if let podcast = episode.podcast {
                Text(podcast.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var compactTitleColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(episode.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(2)

            if let podcast = episode.podcast {
                Text(podcast.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
