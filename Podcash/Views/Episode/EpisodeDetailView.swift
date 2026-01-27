import SwiftUI
import SwiftData

struct EpisodeDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let episode: Episode

    @State private var showCellularConfirmation = false

    private var networkMonitor: NetworkMonitor { NetworkMonitor.shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Artwork
                CachedAsyncImage(url: URL(string: episode.displayArtworkURL ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.2))
                        .overlay {
                            Image(systemName: "mic")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                }
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 8)

                // Title and metadata
                VStack(spacing: 8) {
                    Text(episode.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)

                    if let podcast = episode.podcast {
                        Text(podcast.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Metadata row
                    HStack(spacing: 16) {
                        if let date = episode.publishedDate {
                            Label(date.relativeFormatted, systemImage: "calendar")
                        }

                        if let duration = episode.duration {
                            Label(duration.formattedDuration, systemImage: "clock")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    // Progress indicator if partially played
                    if episode.playbackPosition > 0 && !episode.isPlayed {
                        VStack(spacing: 4) {
                            ProgressView(value: progressValue)
                                .tint(.accentColor)

                            Text(remainingTimeText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal)

                // Play button
                Button {
                    playEpisode()
                } label: {
                    HStack {
                        Image(systemName: episode.playbackPosition > 0 ? "play.fill" : "play.fill")
                        Text(episode.playbackPosition > 0 ? "Continue Playing" : "Play Episode")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canPlay ? Color.accentColor : Color.secondary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!canPlay)
                .padding(.horizontal)

                // Action buttons row
                HStack(spacing: 32) {
                    // Star
                    Button {
                        episode.isStarred.toggle()
                        if episode.isStarred && episode.localFilePath == nil {
                            attemptDownload(isAutoDownload: true)
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: episode.isStarred ? "star.fill" : "star")
                                .font(.title2)
                                .foregroundStyle(episode.isStarred ? .yellow : .secondary)
                            Text(episode.isStarred ? "Starred" : "Star")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    // Download
                    downloadButton

                    // Queue
                    Button {
                        QueueManager.shared.addToQueue(episode)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "text.badge.plus")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("Queue")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    // Play Next
                    Button {
                        QueueManager.shared.playNext(episode)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("Next")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)

                Divider()
                    .padding(.horizontal)

                // Description
                if let description = episode.episodeDescription, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description")
                            .font(.headline)

                        Text(attributedDescription(from: description))
                            .font(.body)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }

                Spacer(minLength: 100)
            }
            .padding(.top)
        }
        .navigationTitle("Episode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        episode.isPlayed.toggle()
                    } label: {
                        Label(
                            episode.isPlayed ? "Mark Unplayed" : "Mark Played",
                            systemImage: episode.isPlayed ? "circle" : "checkmark.circle"
                        )
                    }

                    if let podcast = episode.podcast, podcast.canShare {
                        ShareLink(item: podcast.shareURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Download on Cellular?", isPresented: $showCellularConfirmation) {
            Button("Download") {
                DownloadManager.shared.download(episode)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You're on cellular data. Download anyway?")
        }
    }

    // MARK: - Download Button

    @ViewBuilder
    private var downloadButton: some View {
        if episode.localFilePath != nil {
            Button {
                DownloadManager.shared.deleteDownload(episode)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text("Downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else if let progress = episode.downloadProgress {
            Button {
                DownloadManager.shared.cancelDownload(episode)
            } label: {
                VStack(spacing: 4) {
                    CircularProgressView(progress: progress)
                        .frame(width: 28, height: 28)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                attemptDownload(isAutoDownload: false)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Download")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Computed Properties

    private var canPlay: Bool {
        episode.localFilePath != nil || networkMonitor.isConnected
    }

    private var progressValue: Double {
        guard let duration = episode.duration, duration > 0 else { return 0 }
        return episode.playbackPosition / duration
    }

    private var remainingTimeText: String {
        guard let duration = episode.duration else { return "" }
        let remaining = duration - episode.playbackPosition
        return "\(remaining.formattedDuration) remaining"
    }

    // MARK: - Actions

    private func playEpisode() {
        // Auto-download when playing if not downloaded
        if episode.localFilePath == nil {
            DownloadManager.shared.download(episode)
        }
        AudioPlayerManager.shared.play(episode)
    }

    private func attemptDownload(isAutoDownload: Bool) {
        let result = DownloadManager.shared.checkDownloadAllowed(episode, isAutoDownload: isAutoDownload, context: modelContext)
        switch result {
        case .started:
            DownloadManager.shared.download(episode)
        case .needsConfirmation:
            showCellularConfirmation = true
        case .blocked, .alreadyDownloaded, .alreadyDownloading:
            break
        }
    }

    // MARK: - Description Parsing

    private func attributedDescription(from html: String) -> AttributedString {
        // Try to parse as HTML, fall back to plain text
        let plainText = html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return AttributedString(plainText)
    }
}

#Preview {
    let episode = Episode(
        guid: "123",
        title: "A Very Long Episode Title That Should Wrap to Multiple Lines",
        audioURL: "https://example.com/audio.mp3",
        episodeDescription: "<p>This is a <strong>description</strong> with some HTML content.</p><p>It has multiple paragraphs and should display nicely.</p>",
        duration: 3600,
        publishedDate: Date()
    )
    return NavigationStack {
        EpisodeDetailView(episode: episode)
    }
}
