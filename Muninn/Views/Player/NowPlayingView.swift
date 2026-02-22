import SwiftUI

struct NowPlayingView: View {
    var playerManager = AudioPlayerManager.shared
    var transcriptService = TranscriptService.shared
    var localTranscriptionService = LocalTranscriptionService.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0
    @State private var showTranscript = false

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
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                Spacer()
                if let episode = playerManager.currentEpisode, episode.canShare {
                    ShareLink(item: episode.shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                }
            }
            .padding(.horizontal)

            if let episode = playerManager.currentEpisode {

                // Top section: artwork + title (normal) or compact header + transcript (transcript mode)
                Group {
                    if showTranscript {
                        TranscriptHeaderView(episode: episode) {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                showTranscript = false
                            }
                        }

                        TranscriptView(
                            segments: transcriptService.segments,
                            currentTime: playerManager.currentTime,
                            isLoading: transcriptService.isLoading,
                            error: transcriptService.error,
                            isTranscribing: localTranscriptionService.isTranscribing,
                            transcriptionProgress: localTranscriptionService.progress,
                            canTranscribe: canTranscribeCurrentEpisode,
                            onTranscribe: { startLocalTranscription() },
                            onSeek: { playerManager.seek(to: $0) }
                        )
                    } else {
                        Spacer()

                        // Artwork
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

                        // Title and podcast
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
                .animation(.easeInOut(duration: 0.25), value: showTranscript)

                // Progress slider (always visible)
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
                    .tint(.accentColor)

                    HStack {
                        Text(displayTime.formattedTimestamp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        Spacer()

                        Text(remainingTime.formattedRemaining)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal)
                .padding(.top, 24)

                // Playback controls
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

                // Speed, sleep timer, and actions
                HStack(spacing: 24) {
                    // Speed picker
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
                            Text(formatSpeed(playerManager.effectivePlaybackSpeed))
                            if episode.podcast?.playbackSpeedOverride != nil {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                            }
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                    }

                    // Sleep timer
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
                            if let remaining = playerManager.sleepTimerRemaining {
                                Text(formatSleepTimer(remaining))
                            } else if playerManager.isSleepTimerEndOfEpisode {
                                Text("EP")
                            }
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(playerManager.sleepTimerEndTime != nil ? .indigo : .secondary)
                    }

                    // Star button
                    Button {
                        episode.isStarred.toggle()
                    } label: {
                        Image(systemName: episode.isStarred ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundStyle(episode.isStarred ? .yellow : .secondary)
                    }

                    // Transcript button — always opens the transcript view
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
                            .foregroundStyle(showTranscript ? Color.accentColor : Color.secondary)
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 8)
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
        .presentationDragIndicator(.visible)
        .presentationBackground {
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
                .overlay(Color.black.opacity(0.55))
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
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

    private var displayTime: TimeInterval {
        isDragging ? dragTime : playerManager.currentTime
    }

    private var remainingTime: TimeInterval {
        playerManager.duration - displayTime
    }

    // 0.5, 0.75, then 0.1 increments from 1.0 to 2.0, then 2.5, 3.0
    private let playbackSpeeds: [Double] = [0.5, 0.75] + stride(from: 1.0, through: 2.0, by: 0.1).map { $0 } + [2.5, 3.0]

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
        // SF Symbols has goforward.5, .10, .15, .30, .45, .60, .75, .90
        let validIntervals = [5, 10, 15, 30, 45, 60, 75, 90]
        if validIntervals.contains(interval) {
            return "goforward.\(interval)"
        }
        return "goforward.30"
    }

    private var skipBackwardIcon: String {
        let interval = Int(playerManager.skipBackwardInterval)
        // SF Symbols has gobackward.5, .10, .15, .30, .45, .60, .75, .90
        let validIntervals = [5, 10, 15, 30, 45, 60, 75, 90]
        if validIntervals.contains(interval) {
            return "gobackward.\(interval)"
        }
        return "gobackward.15"
    }

    // MARK: - Local Transcription

    /// True when the current episode can be transcribed on-device:
    /// it must be downloaded and the OS must support SpeechAnalyzer.
    private var canTranscribeCurrentEpisode: Bool {
        guard let episode = playerManager.currentEpisode else { return false }
        guard episode.localFilePath != nil else { return false }
        guard LocalTranscriptionService.isSupported else { return false }
        // Already has a transcript — no need to offer transcription
        guard episode.transcriptURL == nil, episode.localTranscriptPath == nil else { return false }
        return true
    }

    private func startLocalTranscription() {
        guard let episode = playerManager.currentEpisode else { return }
        Task {
            await localTranscriptionService.transcribe(episode: episode, context: modelContext)
        }
    }

}


#Preview {
    NowPlayingView()
}
