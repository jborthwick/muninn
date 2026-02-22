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
    let isTranscribing: Bool
    let transcriptionProgress: Double   // 0.0 – 1.0
    let canTranscribe: Bool             // episode is downloaded + iOS 26+
    let onTranscribe: () -> Void
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
            } else if isTranscribing {
                transcribingView
            } else if let error {
                ContentUnavailableView(
                    "Transcript Unavailable",
                    systemImage: "quote.bubble",
                    description: Text(error)
                )
            } else if segments.isEmpty {
                if canTranscribe {
                    transcribePromptView
                } else {
                    noTranscriptView
                }
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

    // MARK: - Empty State Views

    private var transcribingView: some View {
        VStack(spacing: 20) {
            ProgressView(value: transcriptionProgress)
                .progressViewStyle(.linear)
                .padding(.horizontal, 40)

            Text(transcriptionProgress > 0
                 ? "Transcribing… \(Int(transcriptionProgress * 100))%"
                 : "Starting transcription…")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("This may take a few minutes.\nYou can keep listening while it runs.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var transcribePromptView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Transcript Available")
                .font(.headline)

            Text("Transcribe this episode on-device using Apple Intelligence. Audio stays private and never leaves your device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: onTranscribe) {
                Label("Transcribe Episode", systemImage: "waveform.and.mic")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noTranscriptView: some View {
        VStack(spacing: 12) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Transcript")
                .font(.headline)

            Text(noTranscriptMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noTranscriptMessage: String {
        if #available(iOS 26, *) {
            if LocalTranscriptionService.isSupported {
                // iOS 26, Apple Intelligence available, but episode not downloaded
                return "Download this episode to enable on-device transcription."
            } else {
                // Simulator or device without Apple Intelligence
                return "On-device transcription requires a device with Apple Intelligence."
            }
        } else {
            return "On-device transcription requires iOS 26 or later."
        }
    }

    // MARK: - Segment Row

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
