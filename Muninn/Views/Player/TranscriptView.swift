import SwiftUI

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
    /// Start time of the active group — lets past/future rows avoid reading `playbackTime`
    /// every clock tick (which was forcing full-row AttributedString rebuilds).
    @State private var activeGroupStart: TimeInterval = 0
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
    /// Hide the list until we've scrolled to the playhead (avoids a top-of-transcript flash).
    @State private var hasSettledInitialPosition = false

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
    private func rebuildCache(at time: TimeInterval? = nil) {
        cachedSegmentGroups = buildSegmentGroups()
        let t = time ?? playbackTime
        currentSegmentID = segments.segment(at: t)?.id
        if let segID = currentSegmentID, let group = groupContainingID(segID) {
            setActiveGroup(group)
        }
    }

    /// Sync highlight state to the live player position (playing or paused).
    private func syncToPlayerPosition() {
        let time = playerManager.isPlaying ? playerManager.playbackTime : playerManager.currentTime
        snapPlaybackTime(to: time)
        rebuildCache(at: time)
    }

    /// Scroll to the active group after layout. LazyVStack often needs a second
    /// pass before mid-episode IDs exist, so we retry once without animation.
    /// Keeps the list hidden, then fades in so the top doesn't flash on open.
    private func scheduleScrollToCurrent(proxy: ScrollViewProxy, animation: Animation?) {
        pendingScrollTask?.cancel()
        var hide = Transaction()
        hide.disablesAnimations = true
        withTransaction(hide) { hasSettledInitialPosition = false }

        pendingScrollTask = Task {
            // First pass on the next run loop so the ScrollView exists.
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard !playerManager.isScrubbing, let groupID = activeGroupID else {
                fadeInTranscript()
                return
            }
            scrollToGroup(groupID, proxy: proxy, animation: animation)
            // Second pass once LazyVStack has materialized the destination.
            try? await Task.sleep(for: .milliseconds(48))
            guard !Task.isCancelled else { return }
            if !playerManager.isScrubbing, let groupID = activeGroupID {
                scrollToGroup(groupID, proxy: proxy, animation: nil)
            }
            // Brief hold so the scroll commit isn't visible, then fade in.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            fadeInTranscript()
        }
    }

    private func fadeInTranscript() {
        withAnimation(.easeOut(duration: 0.2)) {
            hasSettledInitialPosition = true
        }
    }

    /// Starts, slows, or stops the highlight clock based on play/scrub state.
    /// - Playing: ~50 ms word-level updates
    /// - Paused: clock off; one-shot sync (cheap)
    /// - Scrubbing: clock off so slider work isn't competing with AttributedString rebuilds
    private func syncPlaybackClock() {
        if playerManager.isScrubbing {
            stopPlaybackClock()
            return
        }
        if playerManager.isPlaying {
            startPlaybackClock(intervalMs: 50)
        } else {
            stopPlaybackClock()
            snapPlaybackTime(to: playerManager.currentTime)
        }
    }

    private func startPlaybackClock(intervalMs: UInt64) {
        playbackClockTask?.cancel()
        snapPlaybackTime(to: playerManager.playbackTime)
        playbackClockTask = Task { @MainActor in
            while !Task.isCancelled {
                if playerManager.isScrubbing || !playerManager.isPlaying {
                    break
                }
                let t = playerManager.playbackTime
                if abs(t - playbackTime) >= 0.02 {
                    playbackTime = t
                    currentSegmentID = segments.segment(at: t)?.id
                }
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
            playbackClockTask = nil
        }
    }

    private func stopPlaybackClock() {
        playbackClockTask?.cancel()
        playbackClockTask = nil
    }

    private func snapPlaybackTime(to time: TimeInterval) {
        playbackTime = time
        currentSegmentID = segments.segment(at: time)?.id
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

    private func setActiveGroup(_ group: [TranscriptSegment]) {
        activeGroupID = group.first?.id
        activeGroupStart = group.first?.startTime ?? 0
    }

    private func scrollToGroup(
        _ groupID: UUID,
        proxy: ScrollViewProxy,
        animation: Animation?
    ) {
        if let animation {
            withAnimation(animation) {
                proxy.scrollTo(groupID, anchor: .center)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(groupID, anchor: .center)
            }
        }
    }

    private func handlePlaybackTimeChange(oldTime: TimeInterval, newTime: TimeInterval, proxy: ScrollViewProxy) {
        // Don't fight the user while scrubbing — animate to the new spot on release.
        guard !playerManager.isScrubbing else { return }

        guard let segID = currentSegmentID,
              let group = groupContainingID(segID),
              let groupID = group.first?.id,
              groupID != activeGroupID else { return }

        let isSeek = abs(newTime - oldTime) > 2.0

        if isSeek {
            pendingScrollTask?.cancel()
            // Brief settle so scrub-release + clock snap don't queue competing scrolls.
            pendingScrollTask = Task {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, !playerManager.isScrubbing else { return }
                setActiveGroup(group)
                scrollToGroup(
                    groupID,
                    proxy: proxy,
                    animation: .easeOut(duration: 0.4)
                )
            }
        } else {
            pendingScrollTask?.cancel()
            setActiveGroup(group)
            // Gentle follow during playback (Apple Podcasts / Pocket Casts style).
            scrollToGroup(
                groupID,
                proxy: proxy,
                animation: .easeInOut(duration: 0.45)
            )
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
                                let groupID = group.first?.id
                                let isCurrent = groupID == activeGroupID
                                TranscriptSegmentGroupRow(
                                    group: group,
                                    isCurrent: isCurrent,
                                    // Only the active row gets the live clock.
                                    playbackTime: isCurrent ? playbackTime : nil,
                                    activeGroupStart: activeGroupStart,
                                    isScrubbing: playerManager.isScrubbing,
                                    accentColor: playerManager.nowPlayingDominantColor,
                                    onSeek: { playerManager.seek(to: $0) }
                                )
                                .equatable()
                                .id(groupID)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    // Stay invisible until scrolled to the playhead, then ease in.
                    .opacity(hasSettledInitialPosition ? 1 : 0)
                    .onChange(of: playbackTime) { oldTime, newTime in
                        handlePlaybackTimeChange(oldTime: oldTime, newTime: newTime, proxy: proxy)
                    }
                    .onAppear {
                        // Open on the spoken line, not the top of the transcript.
                        scheduleScrollToCurrent(proxy: proxy, animation: nil)
                    }
                    // Transcript finished loading after the view appeared.
                    .onChange(of: cachedSegmentGroups.count) { oldCount, newCount in
                        guard oldCount == 0, newCount > 0 else { return }
                        scheduleScrollToCurrent(proxy: proxy, animation: nil)
                    }
                }
            }
        }
        .onAppear {
            syncToPlayerPosition()
            syncPlaybackClock()
        }
        .onDisappear {
            stopPlaybackClock()
            pendingScrollTask?.cancel()
            pendingScrollTask = nil
            hasSettledInitialPosition = false
        }
        .onChange(of: playerManager.isPlaying) { _, _ in
            syncPlaybackClock()
        }
        .onChange(of: playerManager.isScrubbing) { _, scrubbing in
            if scrubbing {
                stopPlaybackClock()
                pendingScrollTask?.cancel()
            } else {
                // Snap highlight to the post-seek position, then resume the clock.
                // Scroll follows via handlePlaybackTimeChange.
                snapPlaybackTime(to: playerManager.currentTime)
                if let segID = currentSegmentID,
                   let group = groupContainingID(segID) {
                    setActiveGroup(group)
                }
                syncPlaybackClock()
            }
        }
        // Skip buttons / external seeks while paused (clock is off).
        .onChange(of: playerManager.currentTime) { _, newTime in
            guard !playerManager.isPlaying, !playerManager.isScrubbing else { return }
            snapPlaybackTime(to: newTime)
        }
        // Rebuild when the transcript is (re)loaded — keyed on the first segment's
        // identity so a full reload is detected even if the count happens to match.
        .onChange(of: segments.first?.id) { _, _ in
            syncToPlayerPosition()
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
        if LocalTranscriptionService.isSupported {
            return "Download this episode to enable on-device transcription."
        } else {
            return "On-device transcription requires a device with Apple Intelligence."
        }
    }

}

// MARK: - Segment Group Row

/// Equatable so past/future rows skip body updates on every highlight-clock tick.
private struct TranscriptSegmentGroupRow: View, Equatable {
    let group: [TranscriptSegment]
    let isCurrent: Bool
    let playbackTime: TimeInterval?
    let activeGroupStart: TimeInterval
    let isScrubbing: Bool
    let accentColor: Color
    let onSeek: (TimeInterval) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isCurrent == rhs.isCurrent
            && lhs.isScrubbing == rhs.isScrubbing
            && lhs.activeGroupStart == rhs.activeGroupStart
            && lhs.group.first?.id == rhs.group.first?.id
            && lhs.accentColor == rhs.accentColor
            && (!lhs.isCurrent || lhs.playbackTime == rhs.playbackTime)
    }

    var body: some View {
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
                Text(attributedText)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(accentColor.opacity(isCurrent ? 0.18 : 0))
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private var attributedText: AttributedString {
        if !isCurrent || playbackTime == nil || isScrubbing {
            let isPast = (group.first?.startTime ?? 0) < activeGroupStart
            let color: Color = {
                if isScrubbing && isCurrent { return Color(UIColor.secondaryLabel) }
                return Color(isPast ? UIColor.label : UIColor.tertiaryLabel)
            }()
            return monochromeString(color: color)
        }

        guard let time = playbackTime else {
            return monochromeString(color: Color(UIColor.tertiaryLabel))
        }
        var result = AttributedString()
        for (i, segment) in group.enumerated() {
            let needsSpace = i < group.count - 1 && !segment.text.hasSuffix(" ")
            let text = needsSpace ? segment.text + " " : segment.text
            var span = AttributedString(text)
            span.foregroundColor = TranscriptHighlight.color(
                playbackTime: time,
                segment: segment
            )
            result += span
        }
        return result
    }

    private func monochromeString(color: Color) -> AttributedString {
        let text = group.enumerated().map { i, segment in
            let needsSpace = i < group.count - 1 && !segment.text.hasSuffix(" ")
            return needsSpace ? segment.text + " " : segment.text
        }.joined()
        var result = AttributedString(text)
        result.foregroundColor = color
        return result
    }
}
