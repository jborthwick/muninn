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
    private static let maxRecapSentences = 4
    private static let maxStorySoFarSentences = 3
    /// Cap beats fed into story-so-far on long episodes so background stays brief.
    private static let storySoFarBeatLimit = 6

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

        guard let transcriptExcerpt = transcriptExcerpt(
            from: start,
            to: currentTime,
            segments: segments
        ) else { return }

        let context = recapContext(from: summary, pausedAt: currentTime)
        let storySoFar = await generateStorySoFar(
            completedBeats: context.completedBeats,
            episodeTitle: episode.title,
            pausedAt: currentTime
        )
        let input = RecapInput(
            transcriptExcerpt: transcriptExcerpt,
            storySoFar: storySoFar,
            currentSegmentTitle: context.currentSegment?.title,
            currentSegmentStart: context.currentSegment?.startTime
        )

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
        You write a quick "catch me up" blurb for someone who paused a podcast mid-episode.
        Write exactly 3 short sentences. Never write more than 4 sentences total.
        Cover ONLY what happened in the RECAP WINDOW transcript — not earlier in the episode.
        Use STORY SO FAR only to disambiguate a name or pronoun. Do not summarize it.
        Use CURRENT SEGMENT only for orientation — never describe unheard content from it.
        Do not quote the transcript verbatim. No bullet points.
        Podcast: "\(episodeTitle)"
        """)
        session.prewarm()

        var prompt = """
        Listener paused at \(ChapterTitleGenerator.formatTime(pausedAt)).
        Summarize what happened in the last \(windowMinutes) minutes only.

        === RECAP WINDOW (primary — your entire answer comes from here) ===
        \(input.transcriptExcerpt)
        """

        if let storySoFar = input.storySoFar, !storySoFar.isEmpty {
            prompt += "\n\n=== STORY SO FAR (background — do not recap in detail) ===\n"
            prompt += storySoFar
        }

        if let title = input.currentSegmentTitle, !title.isEmpty {
            let started = input.currentSegmentStart.map { ChapterTitleGenerator.formatTime($0) } ?? ""
            prompt += "\n\n=== CURRENT SEGMENT (orientation only) ===\n"
            if started.isEmpty {
                prompt += "\"\(title)\" (in progress)"
            } else {
                prompt += "\"\(title)\" (started \(started), in progress)"
            }
        }

        prompt += "\n\nWrite exactly 3 sentences about the recap window only."

        let response = try await session.respond(
            to: prompt,
            generating: PauseRecapPlan.self
        )
        return firstSentences(
            in: response.content.recap.trimmingCharacters(in: .whitespacesAndNewlines),
            max: Self.maxRecapSentences
        )
    }

    @available(iOS 26, *)
    private func storySoFarWithModel(
        completedBeats: [SummaryBeat],
        episodeTitle: String,
        pausedAt: TimeInterval
    ) async throws -> String {
        let beatsForContext = storySoFarBeats(from: completedBeats)
        let beatList = beatsForContext.map { beat in
            let label = beat.title.flatMap { !$0.isEmpty ? $0 : nil } ?? "Segment"
            return "- \(ChapterTitleGenerator.formatTime(beat.startTime)) \(label): \(beat.summary)"
        }.joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
        You write a brief "story so far" for someone partway through a podcast episode.
        Compress only the segments listed below — the listener has fully heard each one.
        Write exactly 2–3 short sentences. Never more than 3 sentences.
        No bullet points. Do not include anything after \(ChapterTitleGenerator.formatTime(pausedAt)).
        Podcast: "\(episodeTitle)"
        """)
        session.prewarm()

        let response = try await session.respond(
            to: "Segments heard so far:\n\(beatList)\n\nWrite exactly 2–3 sentences for the story so far.",
            generating: StorySoFarPlan.self
        )
        return firstSentences(
            in: response.content.storySoFar.trimmingCharacters(in: .whitespacesAndNewlines),
            max: Self.maxStorySoFarSentences
        )
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
        let storySoFar: String?
        let currentSegmentTitle: String?
        let currentSegmentStart: TimeInterval?
    }

    private struct RecapContext {
        let completedBeats: [SummaryBeat]
        let currentSegment: SummaryBeat?
    }

    private func recapContext(from summary: EpisodeSummary?, pausedAt: TimeInterval) -> RecapContext {
        guard let beats = summary?.beats, !beats.isEmpty else {
            return RecapContext(completedBeats: [], currentSegment: nil)
        }
        let completed = beats.filter { $0.endTime <= pausedAt }
        let current = beats.first { $0.startTime <= pausedAt && $0.endTime > pausedAt }
        return RecapContext(completedBeats: completed, currentSegment: current)
    }

    private func transcriptExcerpt(
        from start: TimeInterval,
        to end: TimeInterval,
        segments: [TranscriptSegment]
    ) -> String? {
        let timeline = TranscriptTimeline(segments: segments)
        let transcript = timeline.text(from: start, to: end)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return nil }
        return cappedRecapExcerpt(transcript, maxCharacters: Self.maxRecapContextCharacters)
    }

    private func generateStorySoFar(
        completedBeats: [SummaryBeat],
        episodeTitle: String,
        pausedAt: TimeInterval
    ) async -> String? {
        guard !completedBeats.isEmpty else { return nil }

        let beatsForContext = storySoFarBeats(from: completedBeats)

        if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
            do {
                return try await storySoFarWithModel(
                    completedBeats: beatsForContext,
                    episodeTitle: episodeTitle,
                    pausedAt: pausedAt
                )
            } catch {
                logger.warning("Story so far failed: \(error.localizedDescription)")
            }
        }

        return firstSentences(
            in: storySoFarFallback(from: beatsForContext),
            max: Self.maxStorySoFarSentences
        )
    }

    /// On long episodes, keep only the most recent completed chapters as story-so-far input.
    private func storySoFarBeats(from completedBeats: [SummaryBeat]) -> [SummaryBeat] {
        guard completedBeats.count > Self.storySoFarBeatLimit else { return completedBeats }
        return Array(completedBeats.suffix(Self.storySoFarBeatLimit))
    }

    private func storySoFarFallback(from completedBeats: [SummaryBeat]) -> String {
        let recent = completedBeats.suffix(2).map(\.summary).filter { !$0.isEmpty }
        if !recent.isEmpty {
            return recent.joined(separator: " ")
        }
        return completedBeats.compactMap(\.title).filter { !$0.isEmpty }.joined(separator: "; ")
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

    /// Non-model fallback: last few sentences from the transcript window.
    private func recapFallback(from excerpt: String) -> String {
        let trimmed = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return firstSentences(in: trimmed, max: Self.maxRecapSentences)
    }

    /// Hard cap on model output length when instructions are ignored.
    private func firstSentences(in text: String, max: Int) -> String {
        guard max > 0 else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var sentences: [String] = []
        var buffer = ""

        for character in trimmed {
            buffer.append(character)
            if ".!?…".contains(character) {
                let sentence = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
                buffer = ""
                if sentences.count >= max { break }
            }
        }

        if sentences.count < max {
            let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                sentences.append(tail)
            }
        }

        return sentences.prefix(max).joined(separator: " ")
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
private struct StorySoFarPlan {
    @Guide(description: "Exactly 2–3 short sentences on what the listener has heard so far. Never more than 3 sentences.")
    var storySoFar: String
}

@available(iOS 26, *)
@Generable
private struct PauseRecapPlan {
    @Guide(description: "Exactly 3 short sentences on what just happened in the recap window. Maximum 4 sentences. Do not recap earlier episode content.")
    var recap: String
}
