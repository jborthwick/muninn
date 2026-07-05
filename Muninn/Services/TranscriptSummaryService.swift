import Foundation
import FoundationModels
import SwiftData
import os

@MainActor
@Observable
final class TranscriptSummaryService {
    static let shared = TranscriptSummaryService()

    private(set) var summary: EpisodeSummary?
    private(set) var pauseRecap: String?
    private(set) var isGeneratingRecap = false

    private let logger = Logger(subsystem: "com.muninn", category: "TranscriptSummary")
    private let batchSize = 5

    private init() {}

    // MARK: - Load / clear

    func load(for episode: Episode) {
        guard let url = episode.localSummaryURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            summary = nil
            return
        }
        summary = try? JSONDecoder().decode(EpisodeSummary.self, from: data)
    }

    func clear() {
        summary = nil
        pauseRecap = nil
        isGeneratingRecap = false
    }

    func clearPauseRecap() {
        pauseRecap = nil
    }

    // MARK: - Generation (chapter pipeline)

    func generateSegmentSummaries(
        drafts: [ChapterTitleGenerator.SegmentDraft],
        episodeTitle: String,
        episodeDuration: TimeInterval
    ) async -> [String] {
        guard !drafts.isEmpty else { return [] }

        if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
            do {
                return try await summarizeWithModel(
                    drafts: drafts,
                    episodeTitle: episodeTitle,
                    episodeDuration: episodeDuration
                )
            } catch {
                logger.warning("Segment summarization failed: \(error.localizedDescription)")
            }
        }

        return drafts.map { lexicalSummary(from: $0.excerpt, episodeDuration: episodeDuration) }
    }

    func generateOverview(
        beats: [SummaryBeat],
        episodeTitle: String
    ) async -> String {
        guard !beats.isEmpty else { return "" }

        if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
            do {
                return try await overviewWithModel(beats: beats, episodeTitle: episodeTitle)
            } catch {
                logger.warning("Overview generation failed: \(error.localizedDescription)")
            }
        }

        return beats.map(\.summary).joined(separator: " ")
    }

    func persist(summary: EpisodeSummary, episode: Episode, context: ModelContext) async throws {
        let guid = episode.guid
        let filename = try await Task.detached { [self] in
            try self.saveSummaryToDisk(summary: summary, guid: guid)
        }.value

        episode.localSummaryPath = filename
        try? context.save()
        self.summary = summary
        logger.info("Summary saved: \(filename) (\(summary.beats.count) beats)")
    }

    // MARK: - Pause recap

    private static let maxRecapContextCharacters = 3_500

    func generatePauseRecap(
        episode: Episode,
        segments: [TranscriptSegment],
        currentTime: TimeInterval,
        windowMinutes: Int
    ) async {
        guard windowMinutes > 0, currentTime > 0 else { return }

        isGeneratingRecap = true
        pauseRecap = nil
        defer { isGeneratingRecap = false }

        let window = TimeInterval(windowMinutes * 60)
        let start = max(0, currentTime - window)

        if summary == nil {
            load(for: episode)
        }

        guard let input = buildRecapInput(
            from: start,
            to: currentTime,
            segments: segments,
            summary: summary
        ) else { return }

        if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
            do {
                pauseRecap = try await recapWithModel(
                    input: input,
                    episodeTitle: episode.title,
                    windowMinutes: windowMinutes,
                    pausedAt: currentTime
                )
                return
            } catch {
                logger.warning("Pause recap failed: \(error.localizedDescription)")
            }
        }

        pauseRecap = recapFallback(from: input.transcriptExcerpt)
    }

    // MARK: - FM helpers

    @available(iOS 26, *)
    private func summarizeWithModel(
        drafts: [ChapterTitleGenerator.SegmentDraft],
        episodeTitle: String,
        episodeDuration: TimeInterval
    ) async throws -> [String] {
        let instructions = """
        You summarize podcast transcript segments in one clear sentence each.
        Focus on the story beat, topic, or scene — not filler words or table talk.
        For supporter roll calls or closing credits, say so briefly.
        Podcast: "\(episodeTitle)"
        """

        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()

        var results: [String] = []
        var index = 0
        while index < drafts.count {
            let end = min(index + batchSize, drafts.count)
            let chunk = Array(drafts[index..<end])
            let prompt = summaryPromptBlock(for: chunk)
            let response = try await session.respond(to: prompt, generating: SegmentSummaryBatch.self)
            let batch = normalizedSummaries(
                response.content.summaries,
                drafts: chunk,
                episodeDuration: episodeDuration
            )
            results.append(contentsOf: batch)
            index = end
        }
        return results
    }

    @available(iOS 26, *)
    private func overviewWithModel(beats: [SummaryBeat], episodeTitle: String) async throws -> String {
        let beatList = beats.map { beat in
            "- \(ChapterTitleGenerator.formatTime(beat.startTime)): \(beat.summary)"
        }.joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
        Write a 2–3 sentence overview of a podcast episode from timed segment summaries.
        Podcast: "\(episodeTitle)"
        """)

        let response = try await session.respond(
            to: "Segment summaries:\n\(beatList)\n\nWrite the episode overview.",
            generating: EpisodeOverviewPlan.self
        )
        return response.content.overview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @available(iOS 26, *)
    private func recapWithModel(
        input: RecapInput,
        episodeTitle: String,
        windowMinutes: Int,
        pausedAt: TimeInterval
    ) async throws -> String {
        let session = LanguageModelSession(instructions: """
        You write a quick "catch me up" recap for someone who paused a podcast mid-episode.
        Use the transcript excerpt as your only source of truth — synthesize it in your own words.
        Do not quote the transcript verbatim and do not copy chapter summaries if provided.
        Include concrete details: names, events, decisions, arguments, jokes, or plot turns.
        Skip ads, housekeeping, and filler unless that is all that happened.
        Write 2–4 short sentences in plain, engaging language. No bullet points.
        Podcast: "\(episodeTitle)"
        """)

        var prompt = """
        Listener paused at \(ChapterTitleGenerator.formatTime(pausedAt)).
        Summarize what happened in roughly the last \(windowMinutes) minutes of playback.

        Transcript excerpt:
        \(input.transcriptExcerpt)
        """

        if !input.beatHints.isEmpty {
            prompt += "\n\nChapter context (orientation only — prioritize the transcript window):\n"
            prompt += input.beatHints.joined(separator: "\n")
        }

        let response = try await session.respond(
            to: prompt,
            generating: PauseRecapPlan.self
        )
        return response.content.recap.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func summaryPromptBlock(for drafts: [ChapterTitleGenerator.SegmentDraft]) -> String {
        let segments = drafts.enumerated().map { offset, draft -> String in
            let label = "Segment \(offset + 1) (starts \(ChapterTitleGenerator.formatTime(draft.startTime))):"
            if ChapterTitleGenerator.isRollCallLike(draft.excerpt) {
                return "\(label)\nSupporter roll call or closing credits."
            }
            return "\(label)\n\(draft.excerpt)"
        }.joined(separator: "\n\n")

        return """
        Write exactly one sentence summary per segment below, in the same order.
        Return \(drafts.count) summaries.

        \(segments)
        """
    }

    private func normalizedSummaries(
        _ raw: [String],
        drafts: [ChapterTitleGenerator.SegmentDraft],
        episodeDuration: TimeInterval
    ) -> [String] {
        drafts.indices.map { index in
            let candidate = index < raw.count ? raw[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !candidate.isEmpty { return candidate }
            return lexicalSummary(from: drafts[index].excerpt, episodeDuration: episodeDuration)
        }
    }

    private func lexicalSummary(from excerpt: String, episodeDuration: TimeInterval) -> String {
        if ChapterTitleGenerator.isRollCallLike(excerpt) {
            return "Supporter roll call or closing credits."
        }
        let trimmed = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 120 else { return trimmed }
        let prefix = String(trimmed.prefix(200))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return prefix + "…"
    }

    private struct RecapInput {
        let transcriptExcerpt: String
        let beatHints: [String]
    }

    /// Transcript-first context for recap generation. Chapter beat summaries are hints only.
    private func buildRecapInput(
        from start: TimeInterval,
        to end: TimeInterval,
        segments: [TranscriptSegment],
        summary: EpisodeSummary?
    ) -> RecapInput? {
        let timeline = TranscriptTimeline(segments: segments)
        let transcript = timeline.text(from: start, to: end)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return nil }

        let excerpt = cappedRecapExcerpt(transcript, maxCharacters: Self.maxRecapContextCharacters)
        let beatHints = beatHints(from: start, to: end, in: summary)
        return RecapInput(transcriptExcerpt: excerpt, beatHints: beatHints)
    }

    /// Keep the most recent speech when the window is too long for the model context.
    private func cappedRecapExcerpt(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let suffix = String(text.suffix(maxCharacters))
        if let firstSpace = suffix.firstIndex(of: " ") {
            return "…" + String(suffix[suffix.index(after: firstSpace)...])
        }
        return "…" + suffix
    }

    private func beatHints(
        from start: TimeInterval,
        to end: TimeInterval,
        in summary: EpisodeSummary?
    ) -> [String] {
        guard let beats = summary?.beats, !beats.isEmpty else { return [] }
        return beats
            .filter { $0.endTime > start && $0.startTime < end }
            .suffix(3)
            .map { beat in
                let time = ChapterTitleGenerator.formatTime(beat.startTime)
                if let title = beat.title, !title.isEmpty {
                    return "\(time) — \(title)"
                }
                return "\(time) — \(beat.summary)"
            }
    }

    /// Non-model fallback: last few sentences from the transcript window.
    private func recapFallback(from excerpt: String) -> String {
        let trimmed = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let sentenceChunks = trimmed
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sentenceChunks.count >= 2 {
            return sentenceChunks.suffix(3).joined(separator: ". ") + "."
        }

        return lexicalSummary(from: trimmed, episodeDuration: 0)
    }

    // MARK: - Disk

    nonisolated private func summariesDirectory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private func saveSummaryToDisk(summary: EpisodeSummary, guid: String) throws -> String {
        let data = try JSONEncoder().encode(summary)
        let filename = sanitizedFilename(for: guid) + ".json"
        let url = try summariesDirectory().appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return filename
    }

    nonisolated private func sanitizedFilename(for guid: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        return String(
            guid.unicodeScalars
                .filter { allowed.contains($0) }
                .map(Character.init)
                .prefix(128)
        )
    }
}

@available(iOS 26, *)
@Generable
private struct SegmentSummaryBatch {
    @Guide(description: "One-sentence summaries in segment order.")
    var summaries: [String]
}

@available(iOS 26, *)
@Generable
private struct EpisodeOverviewPlan {
    @Guide(description: "2–3 sentence episode overview.")
    var overview: String
}

@available(iOS 26, *)
@Generable
private struct PauseRecapPlan {
    @Guide(description: "2–4 vivid sentences on what just happened: names, events, and plot turns. Synthesized from the transcript, not copied from chapter summaries.")
    var recap: String
}
