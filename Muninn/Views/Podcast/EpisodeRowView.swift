import SwiftUI
import SwiftData

struct EpisodeRowView: View {
    @Environment(\.modelContext) private var modelContext
    let episode: Episode

    @State private var showCellularConfirmation = false
    @State private var showDeleteDownloadConfirmation = false

    private var isCurrentlyPlaying: Bool {
        AudioPlayerManager.shared.currentEpisode?.guid == episode.guid
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Podcast artwork (always use podcast icon, not episode-specific)
            CachedAsyncImage(url: URL(string: episode.podcast?.artworkURL ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.2))
                    .overlay {
                        Image(systemName: "mic")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                // Title
                Text(episode.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .foregroundStyle(episode.isPlayed ? .secondary : .primary)

                // Metadata row
                HStack(spacing: 6) {
                    // Progress pie indicator if partially played
                    if episode.playbackPosition > 0 && !episode.isPlayed {
                        ProgressPieView(progress: progressValue)
                            .frame(width: 12, height: 12)
                    }

                    if let date = episode.publishedDate {
                        Text(date.relativeFormatted)
                    }

                    if let duration = episode.duration {
                        Text("•")
                        // Show remaining time if partially played
                        if episode.playbackPosition > 0 && !episode.isPlayed {
                            Text(remainingTime)
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Text(duration.formattedDuration)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 8) {
                // Star button
                Button {
                    episode.isStarred.toggle()
                    // Auto-download when starring (respects auto-download preference)
                    if episode.isStarred && episode.localFilePath == nil {
                        let result = DownloadManager.shared.checkDownloadAllowed(episode, isAutoDownload: true, context: modelContext)
                        switch result {
                        case .started:
                            DownloadManager.shared.download(episode)
                        case .needsConfirmation:
                            showCellularConfirmation = true
                        case .blocked, .alreadyDownloaded, .alreadyDownloading:
                            break
                        }
                    }
                } label: {
                    Image(systemName: episode.isStarred ? "star.fill" : "star")
                        .font(.title2)
                        .foregroundStyle(episode.isStarred ? .yellow : .secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)

                // Playing indicator or download button
                if isCurrentlyPlaying {
                    Button {
                        AudioPlayerManager.shared.togglePlayPause()
                    } label: {
                        Image(systemName: AudioPlayerManager.shared.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                } else if episode.localFilePath != nil {
                    Button {
                        showDeleteDownloadConfirmation = true
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                } else if let progress = episode.downloadProgress {
                    Button {
                        DownloadManager.shared.cancelDownload(episode)
                    } label: {
                        CircularProgressView(progress: progress)
                            .frame(width: 22, height: 22)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button {
                        attemptDownload()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .opacity(episode.isPlayed ? 0.7 : 1.0)
        .alert("Download on Cellular?", isPresented: $showCellularConfirmation) {
            Button("Download") {
                DownloadManager.shared.download(episode)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You're on cellular data. Download anyway?")
        }
        .alert("Delete Download?", isPresented: $showDeleteDownloadConfirmation) {
            Button("Delete", role: .destructive) {
                DownloadManager.shared.deleteDownload(episode)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The downloaded file will be removed from your device.")
        }
    }

    private func attemptDownload() {
        let result = DownloadManager.shared.checkDownloadAllowed(episode, isAutoDownload: false, context: modelContext)
        switch result {
        case .started:
            DownloadManager.shared.download(episode)
        case .needsConfirmation:
            showCellularConfirmation = true
        case .blocked, .alreadyDownloaded, .alreadyDownloading:
            break
        }
    }

    private var progressValue: Double {
        guard let duration = episode.duration, duration > 0 else { return 0 }
        return episode.playbackPosition / duration
    }

    private var remainingTime: String {
        guard let duration = episode.duration else { return "" }
        let remaining = duration - episode.playbackPosition
        return remaining.formattedDuration + " left"
    }
}

// MARK: - Circular Progress View (for downloads)

struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 2)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Progress Pie View (small filled pie for playback progress)

struct ProgressPieView: View {
    let progress: Double

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color.secondary.opacity(0.3))

            // Progress pie slice
            PieSlice(progress: progress)
                .fill(Color.accentColor)
        }
    }
}

struct PieSlice: Shape {
    let progress: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let startAngle = Angle(degrees: -90)
        let endAngle = Angle(degrees: -90 + (360 * progress))

        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.closeSubpath()

        return path
    }
}

#Preview {
    let episode = Episode(
        guid: "123",
        title: "Episode Title That Might Be Long",
        audioURL: "https://example.com/audio.mp3",
        episodeDescription: "Description",
        duration: 3600,
        publishedDate: Date()
    )
    return List {
        EpisodeRowView(episode: episode)
    }
}
