import SwiftUI
import SwiftData

struct NowPlayingView: View {
    var playerManager = AudioPlayerManager.shared
    var transcriptService = TranscriptService.shared
    var localTranscriptionService = LocalTranscriptionService.shared
    var chapterService = ChapterService.shared
    var summaryService = TranscriptSummaryService.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @AppStorage("nowPlaying.showTranscript") private var showTranscript = false
    /// GUID of the episode that was playing when showTranscript was last set to true.
    /// Used to detect episode changes that occurred while the player was dismissed.
    @AppStorage("nowPlaying.transcriptEpisodeGUID") private var transcriptEpisodeGUID = ""
    @AppStorage("nowPlaying.showChapters") private var showChapters = false
    /// GUID of the episode that was playing when showChapters was last set to true.
    @AppStorage("nowPlaying.chaptersEpisodeGUID") private var chaptersEpisodeGUID = ""
    @State private var showMarkPlayedConfirmation = false
    @State private var isRecapPopoverVisible = false

    private var appSettings: AppSettings {
        AppSettings.getOrCreate(context: modelContext)
    }

    private var showsWhatsHappening: Bool {
        LocalTranscriptionService.isSupported
            && !showTranscript
            && !showChapters
    }

    /// Backed by AudioPlayerManager so the color is pre-computed before the sheet opens.
    private var dominantColor: Color { playerManager.nowPlayingDominantColor }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Close / more row
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .modifier(GlassCircleModifier())
                }
                Spacer()
                if let episode = playerManager.currentEpisode {
                    moreMenu(for: episode)
                }
            }
            .padding(.horizontal)
            .padding(.top, 16)

            if let episode = playerManager.currentEpisode {
                ZStack(alignment: .bottom) {
                    topSection(for: episode)
                        .animation(.easeInOut(duration: 0.35), value: showTranscript)
                        .animation(.easeInOut(duration: 0.35), value: showChapters)

                    if isRecapPopoverVisible {
                        PauseRecapBanner(
                            text: summaryService.pauseRecap ?? "",
                            isLoading: summaryService.isGeneratingRecap
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .zIndex(1)
                    }
                }
                .frame(maxHeight: .infinity)

                if showsWhatsHappening {
                    whatsHappeningButton
                        .padding(.bottom, 4)
                }

                progressSection
                playbackControls
                actionsRow(for: episode)
            } else {
                Spacer()
                ContentUnavailableView(
                    "Nothing Playing",
                    systemImage: "play.circle",
                    description: Text("Select an episode to play")
                )
                Spacer()
            }
        }
        .tint(dominantColor)
        .animation(.easeInOut(duration: 0.6), value: playerManager.nowPlayingDominantColor)
        .presentationDragIndicator(.visible)
        .presentationBackground { presentationBackground }
        .animation(.easeInOut(duration: 0.25), value: isRecapPopoverVisible)
        .preferredColorScheme(.dark)
        .alert("Mark as Played?", isPresented: $showMarkPlayedConfirmation) {
            Button("Mark as Played", role: .destructive) {
                playerManager.markPlayedAndAdvance()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Marks this episode as played and advances to the next item in your queue.")
        }
        .onAppear {
            // If transcript is persisted open, ensure it's loaded for the *current*
            // episode. The episode may have changed while the player was dismissed,
            // in which case we clear stale segments before reloading so they never
            // appear on screen.
            if showTranscript, let episode = playerManager.currentEpisode {
                if transcriptEpisodeGUID != episode.guid {
                    transcriptService.clear()
                    transcriptEpisodeGUID = episode.guid
                }
                Task { await transcriptService.load(for: episode) }
            }

            // Same stale-data guard for chapters
            if showChapters, let episode = playerManager.currentEpisode {
                if chaptersEpisodeGUID != episode.guid {
                    chapterService.clear()
                    chaptersEpisodeGUID = episode.guid
                }
                chapterService.load(for: episode)
            }

            if let episode = playerManager.currentEpisode {
                summaryService.load(for: episode)
            }
        }
        .onChange(of: playerManager.currentEpisode?.guid) { _, _ in
            // Reset transcript and chapters state when episode changes (while player is open)
            showTranscript = false
            transcriptEpisodeGUID = ""
            transcriptService.clear()
            showChapters = false
            chaptersEpisodeGUID = ""
            chapterService.clear()
            summaryService.clear()
            isRecapPopoverVisible = false
        }
        .onChange(of: playerManager.isPlaying) { _, isPlaying in
            if isPlaying {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isRecapPopoverVisible = false
                }
                summaryService.clearPauseRecap()
            }
        }
        .onChange(of: showTranscript) { _, isOpen in
            if isOpen { isRecapPopoverVisible = false }
        }
        .onChange(of: showChapters) { _, isOpen in
            if isOpen { isRecapPopoverVisible = false }
        }
        .onChange(of: localTranscriptionService.isTranscribing) { wasTranscribing, isTranscribing in
            guard wasTranscribing, !isTranscribing,
                  let episode = playerManager.currentEpisode,
                  showTranscript,
                  episode.localTranscriptPath != nil else { return }
            Task { await transcriptService.load(for: episode) }
        }
        .onChange(of: chapterService.isGenerating) { wasGenerating, isGenerating in
            guard wasGenerating, !isGenerating,
                  let episode = playerManager.currentEpisode,
                  showChapters,
                  chapterService.loadedEpisodeGUID == episode.guid else { return }
            chapterService.load(for: episode)
        }
    }

    // MARK: - Sub-views

    /// Artwork + title in normal mode, compact header + transcript/chapter scroll in panel modes.
    @ViewBuilder
    private func topSection(for episode: Episode) -> some View {
        VStack(spacing: 0) {
            NowPlayingEpisodeHeader(
                episode: episode,
                panel: activePanel,
                onDismissPanel: dismissActivePanel
            )

            if showChapters {
                ChapterView(onGenerate: startChapterGeneration)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if showTranscript {
                TranscriptView(
                    onTranscribe: startLocalTranscription,
                    onCancelTranscription: cancelLocalTranscription,
                    onRetryTranscription: startLocalTranscription
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var activePanel: NowPlayingEpisodeHeader.Panel? {
        if showChapters { return .chapters }
        if showTranscript { return .transcript }
        return nil
    }

    private func dismissActivePanel() {
        withAnimation(.easeInOut(duration: 0.35)) {
            if showChapters { showChapters = false }
            if showTranscript { showTranscript = false }
        }
    }

    /// Scrubber + elapsed / remaining time labels.
    /// Extracted into its own struct so that isDragging/dragTime state changes
    /// only re-render this view, not the full NowPlayingView (and TranscriptView).
    private var progressSection: some View {
        ProgressSectionView()
    }

    /// Skip-back / play-pause / skip-forward buttons.
    private var playbackControls: some View {
        HStack(spacing: 40) {
            Button {
                playerManager.skipBackward()
            } label: {
                Image(systemName: skipBackwardIcon)
                    .font(.system(size: 32))
            }

            Button {
                playerManager.togglePlayPause()
            } label: {
                Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
            }

            Button {
                playerManager.skipForward()
            } label: {
                Image(systemName: skipForwardIcon)
                    .font(.system(size: 32))
            }
            .contextMenu {
                Button {
                    playerManager.markPlayedAndAdvance()
                } label: {
                    Label("Mark as Played", systemImage: "checkmark.circle")
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.top, 24)
    }

    /// Transcript and chapter toggles — other actions live in the top-right more menu.
    @ViewBuilder
    private func actionsRow(for episode: Episode) -> some View {
        HStack(spacing: 48) {
            transcriptButton(for: episode)
            chapterButton(for: episode)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private func moreMenu(for episode: Episode) -> some View {
        Menu {
            if episode.canShare {
                ShareLink(item: episode.shareURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            Menu {
                speedMenuContent(for: episode)
            } label: {
                Label {
                    Text(speedMenuTitle)
                } icon: {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                }
            }

            Menu {
                sleepMenuContent
            } label: {
                Label {
                    Text(sleepMenuTitle)
                } icon: {
                    Image(systemName: "moon.zzz.fill")
                }
            }

            Button {
                episode.isStarred.toggle()
            } label: {
                Label(
                    episode.isStarred ? "Unstar" : "Star",
                    systemImage: episode.isStarred ? "star.slash" : "star"
                )
            }

            Button {
                showMarkPlayedConfirmation = true
            } label: {
                Label("Mark as Played", systemImage: "checkmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .modifier(GlassCircleModifier())
        }
    }

    @ViewBuilder
    private func speedMenuContent(for episode: Episode) -> some View {
        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { speed in
            Button {
                playerManager.playbackSpeed = speed
            } label: {
                HStack {
                    Text(formatSpeed(speed))
                    if abs(playerManager.effectivePlaybackSpeed - speed) < 0.01 {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        if let podcast = episode.podcast {
            Divider()
            Button {
                if podcast.playbackSpeedOverride != nil {
                    podcast.playbackSpeedOverride = nil
                } else {
                    podcast.playbackSpeedOverride = playerManager.effectivePlaybackSpeed
                }
            } label: {
                Label(
                    podcast.playbackSpeedOverride != nil ? "Remove Speed Pin" : "Pin Speed to Podcast",
                    systemImage: podcast.playbackSpeedOverride != nil ? "pin.slash" : "pin"
                )
            }
        }
    }

    @ViewBuilder
    private var sleepMenuContent: some View {
        Button {
            playerManager.cancelSleepTimer()
        } label: {
            HStack {
                Text("Off")
                if playerManager.sleepTimerEndTime == nil {
                    Image(systemName: "checkmark")
                }
            }
        }

        Divider()

        ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
            Button {
                playerManager.setSleepTimer(minutes: minutes)
            } label: {
                Text("\(minutes) min")
            }
        }

        Divider()

        Button {
            playerManager.setSleepTimerEndOfEpisode()
        } label: {
            HStack {
                Text("End of Episode")
                if playerManager.isSleepTimerEndOfEpisode {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func transcriptButton(for episode: Episode) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) {
                if !showTranscript { showChapters = false }  // mutual exclusion
                showTranscript.toggle()
            }
            if showTranscript {
                transcriptEpisodeGUID = episode.guid
                Task { await transcriptService.load(for: episode) }
            }
        } label: {
            Image(systemName: showTranscript ? "quote.bubble.fill" : "quote.bubble")
                .font(.title2)
                .foregroundStyle(showTranscript ? dominantColor : Color.secondary)
        }
    }

    private func chapterButton(for episode: Episode) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) {
                if !showChapters { showTranscript = false }  // mutual exclusion
                showChapters.toggle()
            }
            if showChapters {
                chaptersEpisodeGUID = episode.guid
                chapterService.load(for: episode)
            }
        } label: {
            Image(systemName: showChapters ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                .font(.title2)
                .foregroundStyle(showChapters ? dominantColor : Color.secondary)
        }
    }

    @ViewBuilder
    private var presentationBackground: some View {
        if let episode = playerManager.currentEpisode,
           let urlString = episode.displayArtworkURL,
           let url = URL(string: urlString) {
            CachedAsyncImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.black
            }
            .ignoresSafeArea()
            .blur(radius: 80)
            .overlay(Color.black.opacity(0.72))
            .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    // MARK: - Helpers

    private var speedMenuTitle: String {
        let speed = playerManager.effectivePlaybackSpeed
        if abs(speed - 1.0) > 0.01 {
            return "Speed · \(formatSpeed(speed))"
        }
        return "Speed"
    }

    private var sleepMenuTitle: String {
        if playerManager.isSleepTimerEndOfEpisode {
            return "Sleep · End of Episode"
        }
        if let remaining = playerManager.sleepTimerRemaining {
            return "Sleep · \(formatSleepTimer(remaining))"
        }
        return "Sleep Timer"
    }

    private func formatSpeed(_ speed: Double) -> String {
        if speed == floor(speed) {
            return String(format: "%.0fx", speed)
        } else {
            return String(format: "%.2gx", speed)
        }
    }

    private func formatSleepTimer(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes > 0 {
            return "\(minutes):\(String(format: "%02d", secs))"
        } else {
            return "0:\(String(format: "%02d", secs))"
        }
    }

    private var skipForwardIcon: String {
        let interval = Int(playerManager.skipForwardInterval)
        let validIntervals = [5, 10, 15, 30, 45, 60, 75, 90]
        return validIntervals.contains(interval) ? "goforward.\(interval)" : "goforward.30"
    }

    private var skipBackwardIcon: String {
        let interval = Int(playerManager.skipBackwardInterval)
        let validIntervals = [5, 10, 15, 30, 45, 60, 75, 90]
        return validIntervals.contains(interval) ? "gobackward.\(interval)" : "gobackward.15"
    }

    // MARK: - Local Transcription

    private func startLocalTranscription() {
        guard let episode = playerManager.currentEpisode else { return }
        Task {
            await localTranscriptionService.retryTranscription(episode: episode, context: modelContext)
        }
    }

    private func cancelLocalTranscription() {
        guard let episode = playerManager.currentEpisode else { return }
        Task {
            await localTranscriptionService.cancelTranscription(for: episode, context: modelContext)
        }
    }

    // MARK: - Chapter Generation

    private func startChapterGeneration() {
        guard let episode = playerManager.currentEpisode else { return }
        Task {
            await chapterService.generate(episode: episode, context: modelContext)
            summaryService.load(for: episode)
        }
    }

    private var whatsHappeningButton: some View {
        Button {
            if isRecapPopoverVisible {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isRecapPopoverVisible = false
                }
                summaryService.clearPauseRecap()
            } else {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isRecapPopoverVisible = true
                }
                triggerWhatsHappening()
            }
        } label: {
            Label("What's happening?", systemImage: "sparkles")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isRecapPopoverVisible ? dominantColor : .primary)
    }

    private func triggerWhatsHappening() {
        guard LocalTranscriptionService.isSupported,
              let episode = playerManager.currentEpisode else { return }

        Task {
            await transcriptService.load(for: episode)
            guard !transcriptService.segments.isEmpty else {
                summaryService.clearPauseRecap()
                return
            }
            await summaryService.generatePauseRecap(
                episode: episode,
                segments: transcriptService.segments,
                currentTime: playerManager.currentTime,
                windowMinutes: appSettings.pauseRecapMinutes
            )
        }
    }
}


// MARK: - Progress Section

/// Scrubber and time labels. Owns isDragging/dragTime as local state so that
/// rapid slider updates only re-render this view, not NowPlayingView or TranscriptView.
private struct ProgressSectionView: View {
    var playerManager = AudioPlayerManager.shared
    var chapterService = ChapterService.shared

    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0

    private var displayTime: TimeInterval {
        isDragging ? dragTime : playerManager.currentTime
    }

    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isDragging ? dragTime : playerManager.currentTime },
                    set: { newValue in
                        dragTime = newValue
                        if !isDragging {
                            isDragging = true
                            playerManager.beginScrubbing()
                        }
                    }
                ),
                in: 0...max(playerManager.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        if !isDragging {
                            dragTime = playerManager.currentTime
                            isDragging = true
                            playerManager.beginScrubbing()
                        }
                    } else {
                        playerManager.endScrubbing(at: dragTime)
                        isDragging = false
                    }
                }
            )
            .overlay(alignment: .center) {
                chapterTickMarks
            }

            HStack {
                Text(displayTime.formattedTimestamp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                Text((playerManager.duration - displayTime).formattedRemaining)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal)
        .padding(.top, 24)
    }

    /// Tick marks at chapter boundaries, overlaid on the scrubber track.
    @ViewBuilder
    private var chapterTickMarks: some View {
        let chapters = chapterService.chapters
        let duration = playerManager.duration
        let episodeGUID = playerManager.currentEpisode?.guid
        if chapterService.loadedEpisodeGUID == episodeGUID,
           chapters.count > 1, duration > 0 {
            GeometryReader { geo in
                // Apple's slider draws its track with ~12pt inset from each edge
                // to accommodate the thumb circle.
                let trackInset: CGFloat = 12
                let trackWidth = geo.size.width - trackInset * 2
                let currentTime = isDragging ? dragTime : playerManager.currentTime

                // Skip the first chapter (starts at 0 = left edge of track)
                ForEach(chapters.dropFirst()) { chapter in
                    let x = trackInset + CGFloat(chapter.startTime / duration) * trackWidth
                    let isCurrent = currentTime >= chapter.startTime && currentTime < chapter.endTime
                    Rectangle()
                        .fill(Color.white.opacity(isCurrent ? 0.9 : 0.45))
                        .frame(width: 2, height: 10)
                        .position(x: x, y: geo.size.height / 2)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Glass Circle Button Background

private struct GlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

#if DEBUG
/// In-memory store matching `MuninnApp`'s schema.
/// `cloudKitDatabase: .none` is required — iCloud entitlements otherwise make
/// container setup fail in the preview process (same as `MuninnApp`).
@MainActor
private enum NowPlayingPreviewContainer {
    static let result: Result<ModelContainer, Error> = {
        let schema = Schema([
            Podcast.self,
            Episode.self,
            Folder.self,
            QueueItem.self,
            AppSettings.self,
            ListeningSession.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        do {
            return .success(try ModelContainer(for: schema, configurations: [configuration]))
        } catch {
            return .failure(error)
        }
    }()
}

/// Seeds `AudioPlayerManager`, then shows `NowPlayingView`.
private struct NowPlayingPreviewHost: View {
    var isPlaying: Bool = true
    var currentTime: TimeInterval = 30

    @Environment(\.modelContext) private var modelContext
    @State private var ready = false

    var body: some View {
        Group {
            if ready {
                NowPlayingView()
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: seedIfNeeded)
    }

    private func seedIfNeeded() {
        guard !ready else { return }

        let podcast = Podcast(
            feedURL: "https://example.com/feed",
            title: "NaddPod Patreon Exclusives"
        )
        let episode = Episode(
            guid: "preview-episode-\(isPlaying ? "playing" : "paused")",
            title: "C3 Ep. 28: Pulling Strings (The Dragon Elf Chronicles)",
            audioURL: "https://example.com/audio.mp3",
            duration: 2 * 3600 + 7 * 60 + 30,
            publishedDate: .now
        )
        episode.podcast = podcast
        episode.episodeLink = "https://example.com/episode"
        episode.isStarred = true

        modelContext.insert(podcast)
        modelContext.insert(episode)
        _ = AppSettings.getOrCreate(context: modelContext)

        AudioPlayerManager.shared.preparePreview(
            episode: episode,
            currentTime: currentTime,
            isPlaying: isPlaying
        )
        ready = true
    }
}

private struct NowPlayingPreviewRoot: View {
    var isPlaying: Bool
    var currentTime: TimeInterval

    var body: some View {
        switch NowPlayingPreviewContainer.result {
        case .success(let container):
            NowPlayingPreviewHost(isPlaying: isPlaying, currentTime: currentTime)
                .modelContainer(container)
        case .failure(let error):
            Text("Preview ModelContainer failed:\n\(error.localizedDescription)")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding()
                .containerRelativeFrame([.horizontal, .vertical])
                .background(.black)
        }
    }
}

#Preview("Now Playing") {
    NowPlayingPreviewRoot(isPlaying: true, currentTime: 30)
}

#Preview("Paused") {
    NowPlayingPreviewRoot(isPlaying: false, currentTime: 12 * 60 + 34)
}
#endif
