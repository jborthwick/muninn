import SwiftUI

// MARK: - Compact Header (shown instead of artwork in transcript mode)

struct TranscriptHeaderView: View {
    let episode: Episode
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: URL(string: episode.displayArtworkURL ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                    .overlay {
                        Image(systemName: "mic")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))

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

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "quote.bubble.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Transcript Body

struct TranscriptView: View {
    let segments: [TranscriptSegment]
    let currentTime: TimeInterval
    let isLoading: Bool
    let error: String?
    let onSeek: (TimeInterval) -> Void

    // Track which segment is active to avoid re-scrolling on every 0.5s tick
    @State private var activeSegmentID: UUID?

    private var currentSegment: TranscriptSegment? {
        segments.last(where: { currentTime >= $0.startTime && currentTime < $0.endTime })
            ?? (currentTime > 0 ? segments.last(where: { currentTime >= $0.startTime }) : nil)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading transcript…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView(
                    "Transcript Unavailable",
                    systemImage: "quote.bubble",
                    description: Text(error)
                )
            } else if segments.isEmpty {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "quote.bubble",
                    description: Text("No transcript segments found.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(segments) { segment in
                                segmentRow(segment)
                                    .id(segment.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: currentTime) { _, _ in
                        guard let seg = currentSegment, seg.id != activeSegmentID else { return }
                        activeSegmentID = seg.id
                        withAnimation(.easeInOut(duration: 0.4)) {
                            proxy.scrollTo(seg.id, anchor: .center)
                        }
                    }
                    // Scroll to current position when transcript first opens
                    .onAppear {
                        if let seg = currentSegment {
                            activeSegmentID = seg.id
                            proxy.scrollTo(seg.id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        let isCurrent = segment.id == currentSegment?.id
        let isPast = segment.endTime < currentTime

        Button {
            onSeek(segment.startTime)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = segment.speaker {
                    Text(speaker)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .textCase(.uppercase)
                }
                Text(segment.text)
                    .font(isCurrent ? .body.weight(.medium) : .body)
                    .foregroundStyle(isCurrent ? Color.primary : (isPast ? Color.secondary.opacity(0.6) : Color.secondary))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        isCurrent
                            ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12))
                            : nil
                    )
            }
        }
        .buttonStyle(.plain)
    }
}
