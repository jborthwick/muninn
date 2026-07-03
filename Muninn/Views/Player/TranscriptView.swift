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
    /// Called when the user taps "Transcribe Episode". Needs to be a closure
    /// because the caller holds the SwiftData modelContext.
    let onTranscribe: () -> Void
    let onCancelTranscription: () -> Void
    let onRetryTranscription: () -> Void

    // Services accessed directly — TranscriptView is always showing the
    // currently-playing episode, so there is no value in passing these through.
    private var transcriptService: TranscriptService { TranscriptService.shared }
    private var localTranscriptionService: LocalTranscriptionService { LocalTranscriptionService.shared }
    private var playerManager: AudioPlayerManager { AudioPlayerManager.shared }

    // Track which group is active to avoid re-scrolling on every word tick
    @State private var activeGroupID: UUID? = nil
    // Cancellable scroll task — lets us debounce rapid seeks/scrubs
    @State private var pendingScrollTask: Task<Void, Never>? = nil
    // High-frequency playback clock for word-level highlight (50 ms)
    @State private var playbackTime: TimeInterval = 0
    @State private var playbackClockTask: Task<Void, Never>? = nil

    // Cached to avoid O(n) recomputation on every render.
    // segmentGroups is expensive to build and never changes during playback —
    // only when the transcript loads. currentSegmentID is updated via the
    // playback clock at ~50 ms, not during every render.
    // This makes the render path O(1) so scrubbing the slider stays responsive.
    @State private var cachedSegmentGroups: [[TranscriptSegment]] = []
    @State private var currentSegmentID: UUID? = nil

    // MARK: - Derived from services

    private var segments: [TranscriptSegment] { transcriptService.segments }
    private var isLoading: Bool { transcriptService.isLoading }
    private var error: String? { transcriptService.error }
    private var isTranscribing: Bool {
        guard localTranscriptionService.isTranscribing else { return false }
        return localTranscriptionService.transcribingEpisodeGUID == playerManager.currentEpisode?.guid
    }
    private var isStalledTranscription: Bool {
        guard let episode = playerManager.currentEpisode else { return false }
        return localTranscriptionService.isStalled(episode: episode)
    }
    private var transcriptionProgress: Double {
        playerManager.currentEpisode?.transcriptionProgress ?? localTranscriptionService.progress
    }

    private var canTranscribe: Bool {
        guard let episode = playerManager.currentEpisode else { return false }
        guard episode.localFilePath != nil else { return false }
        guard LocalTranscriptionService.isSupported else { return false }
        // Already has a transcript — no need to offer transcription
        guard episode.transcriptURL == nil, episode.localTranscriptPath == nil else { return false }
        return true
    }

    // MARK: - Cache helpers

    /// Rebuilds cachedSegmentGroups from the current segments and syncs currentSegmentID.
    /// Called once on appear and whenever the transcript is (re)loaded.
    private func rebuildCache() {
        cachedSegmentGroups = buildSegmentGroups()
        currentSegmentID = segments.segment(at: playbackTime)?.id
    }

    private func startPlaybackClock() {
        playbackClockTask?.cancel()
        playbackTime = playerManager.playbackTime
        playbackClockTask = Task { @MainActor in
            while !Task.isCancelled {
                let t = playerManager.playbackTime
                if abs(t - playbackTime) >= 0.02 {
                    playbackTime = t
                    currentSegmentID = segments.segment(at: t)?.id
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopPlaybackClock() {
        playbackClockTask?.cancel()
        playbackClockTask = nil
    }

    private func buildSegmentGroups() -> [[TranscriptSegment]] {
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

    private func groupContainingID(_ id: UUID) -> [TranscriptSegment]? {
        cachedSegmentGroups.first(where: { $0.contains(where: { $0.id == id }) })
    }

    private func handlePlaybackTimeChange(oldTime: TimeInterval, newTime: TimeInterval, proxy: ScrollViewProxy) {
        guard let segID = currentSegmentID,
              let group = groupContainingID(segID),
              let groupID = group.first?.id,
              groupID != activeGroupID else { return }

        let isSeek = abs(newTime - oldTime) > 2.0

        if isSeek {
            pendingScrollTask?.cancel()
            pendingScrollTask = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                activeGroupID = groupID
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo(groupID, anchor: .center)
                }
            }
        } else {
            pendingScrollTask?.cancel()
            activeGroupID = groupID
            withAnimation(.easeInOut(duration: 0.45)) {
                proxy.scrollTo(groupID, anchor: .center)
            }
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading transcript…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isTranscribing {
                transcribingView
            } else if isStalledTranscription {
                stalledTranscriptionView
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
                            ForEach(cachedSegmentGroups, id: \.first?.id) { group in
                                segmentGroupView(group)
                                    .id(group.first?.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: playbackTime) { oldTime, newTime in
                        handlePlaybackTimeChange(oldTime: oldTime, newTime: newTime, proxy: proxy)
                    }
                    .onAppear {
                        if let segID = currentSegmentID,
                           let group = groupContainingID(segID),
                           let groupID = group.first?.id {
                            activeGroupID = groupID
                            proxy.scrollTo(groupID, anchor: .center)
                        }
                    }
                }
            }
        }
        .onAppear {
            rebuildCache()
            startPlaybackClock()
        }
        .onDisappear { stopPlaybackClock() }
        // Rebuild when the transcript is (re)loaded — keyed on the first segment's
        // identity so a full reload is detected even if the count happens to match.
        .onChange(of: segments.first?.id) { _, _ in
            rebuildCache()
            currentSegmentID = segments.segment(at: playbackTime)?.id
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

            Button("Cancel", role: .destructive, action: onCancelTranscription)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var stalledTranscriptionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Transcription Interrupted")
                .font(.headline)

            if transcriptionProgress > 0 {
                Text("Stopped at \(Int(transcriptionProgress * 100))%. You can retry or dismiss.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            HStack(spacing: 12) {
                Button(action: onRetryTranscription) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)

                Button("Dismiss", role: .cancel, action: onCancelTranscription)
                    .buttonStyle(.bordered)
            }
            .font(.subheadline)
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
                return "Download this episode to enable on-device transcription."
            } else {
                return "On-device transcription requires a device with Apple Intelligence."
            }
        } else {
            return "On-device transcription requires iOS 26 or later."
        }
    }

    // MARK: - Segment Group View

    @ViewBuilder
    private func segmentGroupView(_ group: [TranscriptSegment]) -> some View {
        // O(1) — reads cached state, no linear search
        let groupHasCurrent = group.contains(where: { $0.id == currentSegmentID })
        let speaker = group.first?.speaker

        Button {
            playerManager.seek(to: group.first?.startTime ?? 0)
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
                        RoundedRectangle(cornerRadius: 6)
                            .fill(playerManager.nowPlayingDominantColor.opacity(groupHasCurrent ? 0.18 : 0))
                            .animation(.easeInOut(duration: 0.3), value: groupHasCurrent)
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private func groupAttributedString(for group: [TranscriptSegment]) -> AttributedString {
        var result = AttributedString()
        for (i, segment) in group.enumerated() {
            let needsSpace = i < group.count - 1 && !segment.text.hasSuffix(" ")
            let text = needsSpace ? segment.text + " " : segment.text
            var span = AttributedString(text)
            span.foregroundColor = TranscriptHighlight.color(
                playbackTime: playbackTime,
                segment: segment
            )
            result += span
        }
        return result
    }
}
