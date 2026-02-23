import SwiftUI

struct NowPlayingView: View {
    var playerManager = AudioPlayerManager.shared
    var transcriptService = TranscriptService.shared
    var localTranscriptionService = LocalTranscriptionService.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @AppStorage("nowPlaying.showTranscript") private var showTranscript = false
    @State private var showMarkPlayedConfirmation = false
    /// Decoupled from player state so the text appears *after* the Menu closes,
    /// avoiding the clip-during-close-animation artifact.
    @State private var speedLabelActive = false
    @State private var sleepLabelActive = false

    /// Backed by AudioPlayerManager so the color is pre-computed before the sheet opens.
    private var dominantColor: Color { playerManager.nowPlayingDominantColor }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Close / share row
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
                if let episode = playerManager.currentEpisode, episode.canShare {
                    ShareLink(item: episode.shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .modifier(GlassCircleModifier())
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 16)

            if let episode = playerManager.currentEpisode {
                topSection(for: episode)
                    .animation(.easeInOut(duration: 0.25), value: showTranscript)
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
            // Initialise label state to match current player state without animation
            speedLabelActive = abs(playerManager.effectivePlaybackSpeed - 1.0) > 0.01
            sleepLabelActive = playerManager.sleepTimerEndTime != nil
        }
        .onChange(of: playerManager.effectivePlaybackSpeed) { _, newSpeed in
            let active = abs(newSpeed - 1.0) > 0.01
            if active && !speedLabelActive {
                // Delay until the Menu's close animation finishes (~0.35 s) so the
                // label expansion happens outside any active clip animation.
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    speedLabelActive = true
                }
            } else if !active {
                speedLabelActive = false   // going inactive: snap is fine
            }
        }
        .onChange(of: playerManager.sleepTimerEndTime) { _, newEndTime in
            let active = newEndTime != nil
            if active && !sleepLabelActive {
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    sleepLabelActive = true
                }
            } else if !active {
                sleepLabelActive = false
            }
        }
        .onChange(of: playerManager.currentEpisode?.guid) { _, _ in
            // Reset transcript state when episode changes
            showTranscript = false
            transcriptService.clear()
        }
        .onChange(of: localTranscriptionService.isTranscribing) { _, isTranscribing in
            // When transcription finishes, reload the transcript
            if !isTranscribing, let episode = playerManager.currentEpisode, showTranscript {
                Task { await transcriptService.load(for: episode) }
            }
        }
    }

    // MARK: - Sub-views

    /// Artwork + title in normal mode, or compact header + transcript scroll in transcript mode.
    /// The `.animation` for showTranscript is applied at the call site in body.
    @ViewBuilder
    private func topSection(for episode: Episode) -> some View {
        if showTranscript {
            TranscriptHeaderView(episode: episode) {
                withAnimation(.easeInOut(duration: 0.25)) { showTranscript = false }
            }
            TranscriptView(onTranscribe: startLocalTranscription)
        } else {
            Spacer()

            CachedAsyncImage(url: URL(string: episode.displayArtworkURL ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.2))
                    .overlay {
                        Image(systemName: "mic")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 280, height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 10)

            VStack(spacing: 4) {
                Text(episode.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let podcast = episode.podcast {
                    Text(podcast.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 24)

            Spacer()
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

    /// Speed, sleep, star, mark-played, and transcript buttons.
    @ViewBuilder
    private func actionsRow(for episode: Episode) -> some View {
        HStack(spacing: 24) {
            speedMenu(for: episode)
            sleepMenu
            starButton(for: episode)
            markPlayedButton
            transcriptButton(for: episode)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func speedMenu(for episode: Episode) -> some View {
        Menu {
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
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.title2)
                if speedLabelActive {
                    Text(formatSpeed(playerManager.effectivePlaybackSpeed))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .transition(.scale(scale: 0.8, anchor: .leading)
                            .combined(with: .opacity))
                }
                if episode.podcast?.playbackSpeedOverride != nil {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                }
            }
            .foregroundStyle(
                !speedLabelActive && episode.podcast?.playbackSpeedOverride == nil
                    ? Color.secondary : dominantColor
            )
            .animation(.spring(duration: 0.35, bounce: 0.15), value: speedLabelActive)
        }
    }

    private var sleepMenu: some View {
        Menu {
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
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz.fill")
                    .font(.title2)
                    // Suppress animation on the icon only — prevents the moon
                    // disappear glitch while still letting the text animate
                    .animation(nil, value: playerManager.sleepTimerEndTime != nil)
                if sleepLabelActive {
                    let timerText: String = playerManager.isSleepTimerEndOfEpisode ? "EP" :
                        playerManager.sleepTimerRemaining.map { formatSleepTimer($0) } ?? ""
                    Text(timerText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .transition(.scale(scale: 0.8, anchor: .leading)
                            .combined(with: .opacity))
                }
            }
            .foregroundStyle(sleepLabelActive ? dominantColor : .secondary)
            .animation(.spring(duration: 0.35, bounce: 0.15), value: sleepLabelActive)
        }
    }

    private func starButton(for episode: Episode) -> some View {
        Button {
            episode.isStarred.toggle()
        } label: {
            Image(systemName: episode.isStarred ? "star.fill" : "star")
                .font(.title2)
                .foregroundStyle(episode.isStarred ? .yellow : .secondary)
        }
    }

    private var markPlayedButton: some View {
        Button {
            showMarkPlayedConfirmation = true
        } label: {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.secondary)
        }
    }

    private func transcriptButton(for episode: Episode) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                showTranscript.toggle()
            }
            if showTranscript {
                Task { await transcriptService.load(for: episode) }
            }
        } label: {
            Image(systemName: showTranscript ? "quote.bubble.fill" : "quote.bubble")
                .font(.title2)
                .foregroundStyle(showTranscript ? dominantColor : Color.secondary)
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
            await localTranscriptionService.transcribe(episode: episode, context: modelContext)
        }
    }
}


// MARK: - Progress Section

/// Scrubber and time labels. Owns isDragging/dragTime as local state so that
/// rapid slider updates only re-render this view, not NowPlayingView or TranscriptView.
private struct ProgressSectionView: View {
    var playerManager = AudioPlayerManager.shared

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
                        isDragging = true
                    }
                ),
                in: 0...max(playerManager.duration, 1),
                onEditingChanged: { editing in
                    if !editing {
                        playerManager.seek(to: dragTime)
                        isDragging = false
                    }
                }
            )

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

#Preview {
    NowPlayingView()
}
