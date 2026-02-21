import SwiftUI
import AVKit

struct NowPlayingView: View {
    var playerManager = AudioPlayerManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isDragging = false
    @State private var dragTime: TimeInterval = 0
    @State private var showSpeedPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Close button row
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
            }
            .padding(.horizontal)

            if let episode = playerManager.currentEpisode {
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

                // Progress slider
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
                    Button {
                        showSpeedPicker = true
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(playerManager.sleepTimerEndTime != nil ? Color.indigo.opacity(0.2) : Color.secondary.opacity(0.2))
                        .foregroundStyle(playerManager.sleepTimerEndTime != nil ? .indigo : .primary)
                        .clipShape(Capsule())
                    }

                    // Audio output picker
                    AudioRoutePickerButton()
                        .frame(width: 28, height: 28)

                    // Star button
                    Button {
                        episode.isStarred.toggle()
                    } label: {
                        Image(systemName: episode.isStarred ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundStyle(episode.isStarred ? .yellow : .secondary)
                    }

                    // Share button (only if episode can be shared)
                    if episode.canShare {
                        ShareLink(item: episode.shareURL) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 24)

                Spacer()
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
        .sheet(isPresented: $showSpeedPicker) {
            SpeedPickerSheet(
                playerManager: playerManager,
                podcast: playerManager.currentEpisode?.podcast
            )
            .presentationDetents([.medium])
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

}

// MARK: - Speed Picker Sheet

private struct SpeedPickerSheet: View {
    var playerManager: AudioPlayerManager
    var podcast: Podcast?
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSpeed: Double
    @State private var rememberForPodcast: Bool
    private let originalSpeed: Double

    private let speeds: [Double] = [0.5, 0.75] + stride(from: 1.0, through: 2.0, by: 0.1).map { $0 } + [2.5, 3.0]

    init(playerManager: AudioPlayerManager, podcast: Podcast?) {
        self.playerManager = playerManager
        self.podcast = podcast
        let currentSpeed = playerManager.effectivePlaybackSpeed
        self.originalSpeed = currentSpeed
        // Initialize with current effective speed
        _selectedSpeed = State(initialValue: currentSpeed)
        // If podcast already has override, start with toggle on
        _rememberForPodcast = State(initialValue: podcast?.playbackSpeedOverride != nil)
    }

    var body: some View {
        NavigationStack {
            List {
                // Podcast-specific toggle
                if let podcast = podcast {
                    Section {
                        Toggle(isOn: $rememberForPodcast) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Remember for this podcast")
                                Text(podcast.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } footer: {
                        Text(rememberForPodcast
                            ? "Speed will be saved for this podcast only"
                            : "Speed will apply to all podcasts")
                    }
                }

                // Speed options
                Section("Speed") {
                    ForEach(speeds, id: \.self) { speed in
                        Button {
                            selectedSpeed = speed
                            playerManager.previewSpeed(speed)
                        } label: {
                            HStack {
                                Text(formatSpeed(speed))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selectedSpeed == speed {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Playback Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Revert to original speed
                        playerManager.previewSpeed(originalSpeed)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveAndDismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onChange(of: rememberForPodcast) { _, newValue in
                if !newValue {
                    // When toggling off "remember", revert to global speed
                    selectedSpeed = playerManager.globalPlaybackSpeed
                    playerManager.previewSpeed(selectedSpeed)
                }
            }
        }
    }

    private func saveAndDismiss() {
        if let podcast = podcast {
            if rememberForPodcast {
                // Save to podcast override
                podcast.playbackSpeedOverride = selectedSpeed
            } else {
                // Clear podcast override, save to global
                podcast.playbackSpeedOverride = nil
                playerManager.globalPlaybackSpeed = selectedSpeed
            }
        } else {
            // No podcast context, save globally
            playerManager.globalPlaybackSpeed = selectedSpeed
        }

        // Update current playback rate
        playerManager.playbackSpeed = selectedSpeed
        dismiss()
    }

    private func formatSpeed(_ speed: Double) -> String {
        if speed == floor(speed) {
            return String(format: "%.0fx", speed)
        } else {
            return String(format: "%.2gx", speed)
        }
    }
}

// MARK: - Audio Route Picker (UIKit Wrapper)

private struct AudioRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .secondaryLabel
        picker.activeTintColor = .tintColor
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

#Preview {
    NowPlayingView()
}
