import SwiftUI

// MARK: - Chapter Body

struct ChapterView: View {
    /// Called when the user taps "Generate Chapters".
    let onGenerate: () -> Void
    /// Called when the user cancels in-flight generation.
    var onCancel: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext

    private var chapterService: ChapterService { ChapterService.shared }
    private var transcriptService: TranscriptService { TranscriptService.shared }
    private var playerManager: AudioPlayerManager { AudioPlayerManager.shared }

    // Track which chapter is active to avoid re-scrolling on every tick
    @State private var activeChapterID: UUID? = nil
    @State private var showChapterDebug = false

    // MARK: - Derived state

    private var chapters: [Chapter] {
        guard isDisplayingCurrentEpisodeChapters else { return [] }
        return chapterService.chapters
    }
    private var isGenerating: Bool {
        guard let guid = playerManager.currentEpisode?.guid else { return false }
        _ = chapterService.isGenerating
        _ = chapterService.generationStatus
        return chapterService.isGenerating(for: guid)
    }
    private var chapterQueuePosition: (position: Int, total: Int)? {
        guard let guid = playerManager.currentEpisode?.guid else { return nil }
        _ = AutoChapterQueue.shared.queuedGUIDs
        return AutoChapterQueue.shared.queuePosition(for: guid)
    }
    private var isTranscriptionBusy: Bool {
        guard let guid = playerManager.currentEpisode?.guid else { return false }
        _ = LocalTranscriptionService.shared.isTranscribing
        _ = AutoTranscriptionQueue.shared.queuedGUIDs
        if LocalTranscriptionService.shared.isActivelyTranscribing(episodeGUID: guid) {
            return true
        }
        return AutoTranscriptionQueue.shared.queuePosition(for: guid) != nil
    }
    private var error: String? {
        guard let guid = playerManager.currentEpisode?.guid else { return nil }
        return chapterService.errorMessage(for: guid)
    }
    private var isDisplayingCurrentEpisodeChapters: Bool {
        guard let guid = playerManager.currentEpisode?.guid else { return false }
        return chapterService.loadedEpisodeGUID == guid
    }
    private var currentTime: TimeInterval { playerManager.currentTime }

    private var currentChapter: Chapter? {
        chapters.last(where: { currentTime >= $0.startTime })
    }

    private var canGenerate: Bool {
        guard let episode = playerManager.currentEpisode else { return false }
        // Active/queued chapter or transcription work — show progress UI instead of Generate
        guard !isGenerating, chapterQueuePosition == nil, !isTranscriptionBusy else { return false }
        if episode.episodeDescription != nil { return true }
        return !transcriptService.segments.isEmpty
            || episode.localTranscriptPath != nil
            || episode.transcriptURL != nil
    }

    private var chapterDebug: ChapterGenerationDebugInfo? {
        guard let guid = playerManager.currentEpisode?.guid else { return nil }
        return chapterService.chapterDebug(
            episodeGUID: guid,
            chapters: chapters,
            overview: chapterService.overview
        )
    }

    // MARK: - Body

    var body: some View {
        Group {
            if isGenerating {
                generatingView
            } else if let queuePosition = chapterQueuePosition {
                chaptersQueuedView(position: queuePosition.position, total: queuePosition.total)
            } else if let error {
                ContentUnavailableView(
                    "Chapters Unavailable",
                    systemImage: "list.bullet.rectangle",
                    description: Text(error)
                )
            } else if chapters.isEmpty {
                if isTranscriptionBusy {
                    waitingForTranscriptionView
                } else if canGenerate {
                    generatePromptView
                } else {
                    noChaptersView
                }
            } else {
                chapterListView
            }
        }
        .overlay(alignment: .topTrailing) {
            if chapterDebug != nil, !isGenerating, chapterQueuePosition == nil {
                Button { showChapterDebug = true } label: {
                    Image(systemName: "ladybug")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Chapter debug")
                .padding(.top, 8)
                .padding(.trailing, 12)
            }
        }
        .sheet(isPresented: $showChapterDebug) {
            if let debug = chapterDebug {
                ChapterGenerationDebugView(debug: debug)
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

                if canGenerate {
                    Button(action: onGenerate) {
                        Label("Regenerate Chapters", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 14)
                }
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

            if playerManager.currentEpisode != nil {
                Button("Cancel", role: .destructive) {
                    onCancel?()
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func chaptersQueuedView(position: Int, total: Int) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.2)

            Text("Queued for chapters")
                .font(.headline)

            Text("\(position) of \(total) in queue")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("You can keep listening. Chapter generation starts when earlier episodes finish.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Remove from Queue", role: .destructive) {
                onCancel?()
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var waitingForTranscriptionView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.2)

            let transcribing = playerManager.currentEpisode.map {
                LocalTranscriptionService.shared.isActivelyTranscribing(episodeGUID: $0.guid)
            } ?? false

            Text(transcribing ? "Transcribing first…" : "Queued for transcription")
                .font(.headline)

            if !transcribing, let guid = playerManager.currentEpisode?.guid,
               let position = AutoTranscriptionQueue.shared.queuePosition(for: guid) {
                Text("\(position.position) of \(position.total) in transcription queue")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Chapters will generate after the transcript is ready. You can keep listening.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let episode = playerManager.currentEpisode {
                Button(transcribing ? "Cancel Transcription" : "Remove from Queue", role: .destructive) {
                    Task {
                        await LocalTranscriptionService.shared.cancelTranscription(
                            for: episode,
                            context: modelContext
                        )
                    }
                }
                .font(.subheadline)
            }
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
            return "Uses show note chapters when available, otherwise detects topics from the transcript and writes titles on-device with Apple Intelligence."
        } else {
            return "Uses show note chapters when available, otherwise detects topics from the transcript. Titled chapters require Apple Intelligence."
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
        "Transcribe this episode, or add timestamped chapters to the episode description, to enable chapter generation."
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
