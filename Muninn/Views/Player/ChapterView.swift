import SwiftUI

// MARK: - Compact Header (shown instead of artwork in chapters mode)

struct ChapterHeaderView: View {
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
                Image(systemName: "list.bullet.rectangle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Chapter Body

struct ChapterView: View {
    /// Called when the user taps "Generate Chapters".
    let onGenerate: () -> Void

    private var chapterService: ChapterService { ChapterService.shared }
    private var transcriptService: TranscriptService { TranscriptService.shared }
    private var playerManager: AudioPlayerManager { AudioPlayerManager.shared }

    // Track which chapter is active to avoid re-scrolling on every tick
    @State private var activeChapterID: UUID? = nil

    // MARK: - Derived state

    private var chapters: [Chapter] { chapterService.chapters }
    private var isGenerating: Bool { chapterService.isGenerating }
    private var error: String? { chapterService.error }
    private var currentTime: TimeInterval { playerManager.currentTime }

    private var currentChapter: Chapter? {
        chapters.last(where: { currentTime >= $0.startTime })
    }

    private var canGenerate: Bool {
        guard let episode = playerManager.currentEpisode else { return false }
        // Boundary detection works on all devices; just needs a transcript
        return !transcriptService.segments.isEmpty
            || episode.localTranscriptPath != nil
            || episode.transcriptURL != nil
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isGenerating {
                generatingView
            } else if let error {
                ContentUnavailableView(
                    "Chapters Unavailable",
                    systemImage: "list.bullet.rectangle",
                    description: Text(error)
                )
            } else if chapters.isEmpty {
                if canGenerate {
                    generatePromptView
                } else {
                    noChaptersView
                }
            } else {
                chapterListView
            }
        }
        .onChange(of: currentTime) { _, newTime in
            guard let chapter = currentChapter,
                  chapter.id != activeChapterID else { return }
            activeChapterID = chapter.id
        }
    }

    // MARK: - Chapter List

    private var chapterListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        chapterRow(chapter, index: index + 1)
                            .id(chapter.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()
                    .padding(.horizontal)

                Button(action: onGenerate) {
                    Label("Regenerate Chapters", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 14)
            }
            .onChange(of: activeChapterID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
            .onAppear {
                if let chapter = currentChapter {
                    activeChapterID = chapter.id
                    proxy.scrollTo(chapter.id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func chapterRow(_ chapter: Chapter, index: Int) -> some View {
        let isCurrent = chapter.id == currentChapter?.id

        Button {
            playerManager.seek(to: chapter.startTime)
        } label: {
            HStack(spacing: 12) {
                // Chapter number
                Text(String(format: "%02d", index))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 24, alignment: .trailing)

                // Chapter title
                Text(chapter.title)
                    .font(.body)
                    .foregroundStyle(isCurrent ? Color.primary : Color(UIColor.secondaryLabel))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)

                // Start time
                Text(formatTime(chapter.startTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(playerManager.nowPlayingDominantColor.opacity(isCurrent ? 0.18 : 0))
                    .animation(.easeInOut(duration: 0.3), value: isCurrent)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State Views

    private var generatingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.2)

            let status = chapterService.generationStatus
            Text(status.isEmpty ? "Generating Chapters…" : status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .animation(.easeInOut(duration: 0.2), value: status)

            Text("You can keep listening while chapters generate.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var generatePromptView: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Chapters Yet")
                .font(.headline)

            Text(generatePromptDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: onGenerate) {
                Label("Generate Chapters", systemImage: "list.bullet.rectangle")
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

    private var generatePromptDescription: String {
        if ChapterService.titlesSupported {
            return "Detect topic boundaries and generate chapter titles using Apple Intelligence. Everything stays on-device."
        } else {
            return "Detect topic boundaries from this episode's transcript. Chapter titles require Apple Intelligence."
        }
    }

    private var noChaptersView: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Chapters")
                .font(.headline)

            Text(noChaptersMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noChaptersMessage: String {
        "Transcribe this episode first to enable chapter generation."
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        let totalSecs = Int(seconds)
        let h = totalSecs / 3600
        let m = (totalSecs % 3600) / 60
        let s = totalSecs % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
}
