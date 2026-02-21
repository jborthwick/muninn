import SwiftUI
import SwiftData

struct EpisodeDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let episode: Episode

    @State private var showCellularConfirmation = false
    @State private var showDeleteDownloadConfirmation = false
    @State private var parsedDescription: AttributedString?

    private var networkMonitor: NetworkMonitor { NetworkMonitor.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Drag indicator
                    Capsule()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 36, height: 5)
                        .padding(.top, 8)

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
                                Label(date.fullFormatted, systemImage: "calendar")
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
                            toggleStar()
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
                            if QueueManager.shared.isInQueue(episode) {
                                QueueManager.shared.removeFromQueue(episode)
                            } else {
                                QueueManager.shared.addToQueue(episode)
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: QueueManager.shared.isInQueue(episode) ? "text.badge.checkmark" : "text.badge.plus")
                                    .font(.title2)
                                    .foregroundStyle(QueueManager.shared.isInQueue(episode) ? .indigo : .secondary)
                                Text(QueueManager.shared.isInQueue(episode) ? "Queued" : "Queue")
                                    .font(.caption)
                                    .foregroundStyle(QueueManager.shared.isInQueue(episode) ? .indigo : .secondary)
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

                            if let parsed = parsedDescription {
                                Text(parsed)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                            } else {
                                Text(attributedDescription(from: description))
                                    .font(.body)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .task {
                            if parsedDescription == nil {
                                parsedDescription = parseHTML(description)
                            }
                        }
                    }

                    Spacer(minLength: 100)
                }
            }
            .navigationTitle("Episode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }

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

                        if episode.canShare {
                            ShareLink(item: episode.shareURL) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden) // We have our own
        .interactiveDismissDisabled(false)
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

    // MARK: - Download Button

    @ViewBuilder
    private var downloadButton: some View {
        if episode.localFilePath != nil {
            Button {
                showDeleteDownloadConfirmation = true
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
        dismiss()
    }

    private func toggleStar() {
        episode.isStarred.toggle()
        if episode.isStarred && episode.localFilePath == nil {
            attemptDownload(isAutoDownload: true)
        }
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
        // Quick plain-text fallback (used while async HTML parse runs)
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

    /// Parses HTML description into an AttributedString with tappable links.
    private func parseHTML(_ html: String) -> AttributedString? {
        let textColor = UIColor.label.cssColor
        let linkColor = UIColor.tintColor.cssColor
        let styledHTML = """
        <html><head><style>
        body { font-family: -apple-system; font-size: 17px; color: \(textColor); }
        a { color: \(linkColor); }
        </style></head><body>\(html)</body></html>
        """

        guard let data = styledHTML.data(using: .utf8),
              let nsAttr = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue
                  ],
                  documentAttributes: nil
              ) else {
            return nil
        }

        return try? AttributedString(nsAttr, including: \.uiKit)
    }
}

// MARK: - UIColor CSS Helper

extension UIColor {
    /// Returns a CSS-compatible rgba() color string.
    var cssColor: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return "rgba(\(Int(r * 255)),\(Int(g * 255)),\(Int(b * 255)),\(String(format: "%.2f", a)))"
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
    return EpisodeDetailView(episode: episode)
}
