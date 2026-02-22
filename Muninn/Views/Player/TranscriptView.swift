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

    // Track which group is active to avoid re-scrolling on every 0.5s tick
    @State private var activeGroupID: UUID?

    private var currentSegment: TranscriptSegment? {
        segments.last(where: { currentTime >= $0.startTime && currentTime < $0.endTime })
            ?? (currentTime > 0 ? segments.last(where: { currentTime >= $0.startTime }) : nil)
    }

    /// Segments grouped into paragraph-sized chunks, breaking on sentence-ending
    /// punctuation or when a chunk exceeds ~200 characters.
    private var segmentGroups: [[TranscriptSegment]] {
        var groups: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var charCount = 0
        for seg in segments {
            current.append(seg)
            charCount += seg.text.count
            let trimmed = seg.text.trimmingCharacters(in: .whitespaces)
            let endsSentence = trimmed.hasSuffix(".") || trimmed.hasSuffix("?")
                || trimmed.hasSuffix("!") || trimmed.hasSuffix("…")
            if endsSentence || charCount >= 200 {
                groups.append(current)
                current = []
                charCount = 0
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private func groupContaining(_ segment: TranscriptSegment) -> [TranscriptSegment]? {
        segmentGroups.first(where: { $0.contains(where: { $0.id == segment.id }) })
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
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(segmentGroups, id: \.first?.id) { group in
                                segmentGroupView(group)
                                    .id(group.first?.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: currentTime) { _, _ in
                        guard let seg = currentSegment,
                              let group = groupContaining(seg),
                              let groupID = group.first?.id,
                              groupID != activeGroupID else { return }
                        activeGroupID = groupID
                        withAnimation(.easeInOut(duration: 0.4)) {
                            proxy.scrollTo(groupID, anchor: .center)
                        }
                    }
                    .onAppear {
                        if let seg = currentSegment,
                           let group = groupContaining(seg),
                           let groupID = group.first?.id {
                            activeGroupID = groupID
                            proxy.scrollTo(groupID, anchor: .center)
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

    // MARK: - Segment Group View

    @ViewBuilder
    private func segmentGroupView(_ group: [TranscriptSegment]) -> some View {
        let groupHasCurrent = group.contains(where: { $0.id == currentSegment?.id })
        let speaker = group.first?.speaker

        Button {
            onSeek(group.first?.startTime ?? 0)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if let speaker {
                    Text(speaker)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .textCase(.uppercase)
                }
                Text(groupAttributedString(for: group))
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        groupHasCurrent
                            ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12))
                            : nil
                    )
            }
        }
        .buttonStyle(.plain)
    }

    /// Builds an AttributedString for a group, colouring each segment by playback state.
    private func groupAttributedString(for group: [TranscriptSegment]) -> AttributedString {
        var result = AttributedString()
        for (i, segment) in group.enumerated() {
            let text = i < group.count - 1 ? segment.text + " " : segment.text
            var span = AttributedString(text)
            let isCurrent = segment.id == currentSegment?.id
            let isPast = segment.endTime < currentTime
            if isCurrent {
                span.foregroundColor = .primary
                span.font = .body.weight(.semibold)
            } else if isPast {
                span.foregroundColor = Color(UIColor.tertiaryLabel)
            } else {
                span.foregroundColor = Color(UIColor.secondaryLabel)
            }
            result += span
        }
        return result
    }
}
