import Foundation
import FoundationModels
import os

struct ChapterBeat: Equatable, Sendable {
    let summary: String
    let title: String
}

struct ChapterBeatsResult: Equatable {
    let beats: [ChapterBeat]
    let entries: [ChapterBeatDebugEntry]
}

@MainActor
@Observable
final class TranscriptSummaryService {
    static let shared = TranscriptSummaryService()

    private(set) var pauseRecap: String?
    private(set) var pauseRecapNeedsChapters = false
    private(set) var isGeneratingRecap = false
    private(set) var lastRecapDebug: PauseRecapDebugInfo?

    private let logger = Logger(subsystem: "com.muninn", category: "TranscriptSummary")

    private static let maxChapterTranscriptCharacters = 9_000
    private static let chunkTranscriptCharacters = 8_000
    private static let maxPartialHeardCharacters = 2_500
    private static let maxUsableBeatSummaryCharacters = 280
    private static let maxRecapSentences = 4
    private static let storySoFarBeatLimit = 8
    /// Keep all completed chapters when their combined summary text fits this budget.
    private static let maxBeatInputCharacters = 2_800
    private static let directJoinBeatLimit = 4

    private init() {}

    // MARK: - Clear

    func clear() {
        pauseRecap = nil
        pauseRecapNeedsChapters = false
        isGeneratingRecap = false
    }

    func clearPauseRecap() {
        pauseRecap = nil
        pauseRecapNeedsChapters = false
    }

    func clearRecapDebug() {
        lastRecapDebug = nil
    }

    // MARK: - Chapter beat generation

    func generateChapterBeats(
        drafts: [ChapterTitleGenerator.SegmentDraft],
        episodeTitle: String,
        episodeDuration: TimeInterval
    ) async -> ChapterBeatsResult {
        guard !drafts.isEmpty else { return ChapterBeatsResult(beats: [], entries: []) }

        var beats: [ChapterBeat] = []
        var entries: [ChapterBeatDebugEntry] = []
        for (index, draft) in drafts.enumerated() {
            let result = await generateSingleChapterBeat(
                draft: draft,
                index: index,
                draftCount: drafts.count,
                episodeTitle: episodeTitle,
                episodeDuration: episodeDuration
            )
            beats.append(result.beat)
            entries.append(result.entry)
        }
        return ChapterBeatsResult(beats: beats, entries: entries)
    }

    func generateOverview(
        chapters: [Chapter],
        episodeTitle: String
    ) async -> (text: String, error: String?) {
        let summaries = chapters.compactMap { chapter -> (TimeInterval, String)? in
            guard let summary = chapter.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !summary.isEmpty else { return nil }
            return (chapter.startTime, summary)
        }
        guard !summaries.isEmpty else { return ("", nil) }

        if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
            do {
                let text = try await overviewWithModel(summaries: summaries, episodeTitle: episodeTitle)
                return (text, nil)
            } catch {
                logger.warning("Overview generation failed: \(error.localizedDescription)")
                let fallback = summaries.map(\.1).joined(separator: " ")
                return (fallback, error.localizedDescription)
            }
        }

        let fallback = summaries.map(\.1).joined(separator: " ")
        return (fallback, nil)
    }

    // MARK: - Pause recap

    func generatePauseRecap(
        episode: Episode,
        segments: [TranscriptSegment],
        currentTime: TimeInterval,
        chapters: [Chapter] = []
    ) async {
        guard currentTime > 0 else { return }

        isGeneratingRecap = true
        pauseRecap = nil
        pauseRecapNeedsChapters = false
        var debug = PauseRecapDebugInfo()
        debug.pausedAt = currentTime
        defer {
            isGeneratingRecap = false
            lastRecapDebug = debug
        }

        debug.totalBeatCount = chapters.count

        let build = await buildRecapInput(
            chapters: chapters,
            segments: segments,
            currentTime: currentTime,
            episodeTitle: episode.title
        )
        debug.completedBeatCount = build.completedCount
        debug.skippedEmptyBeatCount = build.skippedEmpty
        debug.cappedBeatCount = build.cappedCount
        debug.hasInProgressChapter = build.inProgressTitle != nil
        debug.inProgressChapterTitle = build.inProgressTitle
        debug.inProgressRange = build.inProgressRange
        debug.partialSummary = build.partialSummary
        debug.partialExcerptPreview = build.partialExcerptPreview
        debug.beatInput = build.beatLines.map { "- \($0)" }.joined(separator: "\n")

        guard !build.beatLines.isEmpty else {
            pauseRecapNeedsChapters = true
            debug.needsChapters = true
            return
        }

        if build.beatLines.count <= Self.directJoinBeatLimit {
            let text = directRecap(from: build.beatSummaries)
            pauseRecap = text
            debug.usedDirectJoin = true
            debug.recapFinalText = text
            return
        }

        let beatList = build.beatLines.map { "- \($0)" }.joined(separator: "\n")
        let prompt = "Chapters heard so far:\n\(beatList)\n\nWrite the story so far in 2–4 sentences."
        debug.recapPrompt = prompt

        if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
            do {
                let result = try await compressBeatsToRecap(
                    beatLines: build.beatLines,
                    episodeTitle: episode.title,
                    currentTime: currentTime
                )
                pauseRecap = result.text
                debug.recapRawResponse = result.raw
                debug.usedFoundationModel = true
                debug.recapFinalText = result.text
                return
            } catch {
                debug.recapError = error.localizedDescription
                logger.warning("Pause recap failed: \(error.localizedDescription)")
            }
        } else {
            debug.recapError = "Foundation Models unavailable."
        }

        let fallback = lexicalRecapFallback(from: build.beatSummaries)
        pauseRecap = fallback
        debug.usedFallback = true
        debug.recapFinalText = fallback
    }

    // MARK: - Chapter beat FM helpers

    private func generateSingleChapterBeat(
        draft: ChapterTitleGenerator.SegmentDraft,
        index: Int,
        draftCount: Int,
        episodeTitle: String,
        episodeDuration: TimeInterval
    ) async -> (beat: ChapterBeat, entry: ChapterBeatDebugEntry) {
        let transcriptChars = draft.transcript.count
        let excerptPreview = debugExcerptPreview(draft.excerpt)

        func entry(
            beat: ChapterBeat,
            source: String,
            flaggedRollCall: Bool,
            usedChunking: Bool,
            error: String?
        ) -> (beat: ChapterBeat, entry: ChapterBeatDebugEntry) {
            let debugEntry = ChapterBeatDebugEntry(
                index: index,
                startTime: draft.startTime,
                endTime: 0,
                title: beat.title,
                summary: beat.summary,
                source: source,
                flaggedRollCall: flaggedRollCall,
                transcriptCharacters: transcriptChars,
                excerptPreview: excerptPreview,
                usedChunking: usedChunking,
                error: error
            )
            return (beat, debugEntry)
        }

        if ChapterTitleGenerator.isRollCallLike(
            draft.transcript,
            startTime: draft.startTime,
            episodeDuration: episodeDuration
        ) {
            let beat = ChapterBeat(
                summary: ChapterTitleGenerator.rollCallSummary(),
                title: ChapterTitleGenerator.rollCallTitle(
                    startTime: draft.startTime,
                    index: index,
                    draftCount: draftCount,
                    episodeDuration: episodeDuration
                )
            )
            return entry(beat: beat, source: "roll_call", flaggedRollCall: true, usedChunking: false, error: nil)
        }

        if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
            do {
                let modelResult = try await chapterBeatWithModel(
                    transcript: draft.transcript,
                    startTime: draft.startTime,
                    episodeTitle: episodeTitle
                )
                return entry(
                    beat: modelResult.beat,
                    source: modelResult.usedPermissiveFallback
                        ? "foundation_model_permissive"
                        : "foundation_model",
                    flaggedRollCall: false,
                    usedChunking: modelResult.usedChunking,
                    error: nil
                )
            } catch {
                logger.warning("Chapter beat generation failed: \(error.localizedDescription)")
                let beat = ChapterBeat(
                    summary: "",
                    title: ChapterTitleGenerator.lexicalTitle(from: draft.excerpt, startTime: draft.startTime)
                )
                return entry(
                    beat: beat,
                    source: "lexical_fallback",
                    flaggedRollCall: false,
                    usedChunking: false,
                    error: error.localizedDescription
                )
            }
        }

        let beat = ChapterBeat(
            summary: "",
            title: ChapterTitleGenerator.lexicalTitle(from: draft.excerpt, startTime: draft.startTime)
        )
        return entry(beat: beat, source: "lexical_fallback", flaggedRollCall: false, usedChunking: false, error: nil)
    }

    private func debugExcerptPreview(_ text: String, limit: Int = 240) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    @available(iOS 26, *)
    private struct ChapterModelResult {
        let beat: ChapterBeat
        let usedChunking: Bool
        let usedPermissiveFallback: Bool
    }

    @available(iOS 26, *)
    private func chapterBeatWithModel(
        transcript: String,
        startTime: TimeInterval,
        episodeTitle: String
    ) async throws -> ChapterModelResult {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "TranscriptSummary", code: 1, userInfo: nil)
        }

        do {
            let guided = try await chapterBeatWithGuidedGeneration(
                transcript: trimmed,
                startTime: startTime,
                episodeTitle: episodeTitle
            )
            return ChapterModelResult(
                beat: guided.beat,
                usedChunking: guided.usedChunking,
                usedPermissiveFallback: false
            )
        } catch {
            logger.warning("Guided chapter beat failed, trying permissive String: \(error.localizedDescription)")
            let permissive = try await chapterBeatWithPermissiveString(
                transcript: trimmed,
                startTime: startTime,
                episodeTitle: episodeTitle
            )
            return ChapterModelResult(
                beat: permissive.beat,
                usedChunking: permissive.usedChunking,
                usedPermissiveFallback: true
            )
        }
    }

    @available(iOS 26, *)
    private func chapterBeatWithGuidedGeneration(
        transcript: String,
        startTime: TimeInterval,
        episodeTitle: String
    ) async throws -> (beat: ChapterBeat, usedChunking: Bool) {
        let instructions = chapterBeatInstructions(episodeTitle: episodeTitle)
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()

        let plan: ChapterBeatPlan
        let usedChunking: Bool
        if transcript.count <= Self.maxChapterTranscriptCharacters {
            let prompt = chapterBeatPrompt(transcript: transcript, startTime: startTime)
            let response = try await session.respond(to: prompt, generating: ChapterBeatPlan.self)
            plan = response.content
            usedChunking = false
        } else {
            plan = try await chapterBeatFromChunks(
                transcript: transcript,
                startTime: startTime,
                session: session
            )
            usedChunking = true
        }

        let summary = plan.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsableBeatSummary(summary), !title.isEmpty else {
            throw NSError(domain: "TranscriptSummary", code: 2, userInfo: nil)
        }
        return (ChapterBeat(summary: summary, title: title), usedChunking)
    }

    @available(iOS 26, *)
    private func chapterBeatWithPermissiveString(
        transcript: String,
        startTime: TimeInterval,
        episodeTitle: String
    ) async throws -> (beat: ChapterBeat, usedChunking: Bool) {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(
            model: model,
            instructions: chapterBeatInstructions(episodeTitle: episodeTitle)
        )
        session.prewarm()

        if transcript.count <= Self.maxChapterTranscriptCharacters {
            let prompt = chapterBeatPermissivePrompt(transcript: transcript, startTime: startTime)
            let response = try await session.respond(to: prompt)
            let beat = try parseTitleAndSummary(response.content)
            return (beat, false)
        }

        let chunks = splitTranscriptIntoChunks(transcript, maxSize: Self.chunkTranscriptCharacters)
        var partSummaries: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let prompt = """
            Part \(index + 1) of \(chunks.count) (chapter starts \(ChapterTitleGenerator.formatTime(startTime))):

            \(chunk)

            Write exactly one sentence summarizing this part.
            """
            let response = try await session.respond(to: prompt)
            let part = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty, !looksLikeModelRefusal(part) else { continue }
            partSummaries.append(part)
        }

        guard !partSummaries.isEmpty else {
            throw NSError(domain: "TranscriptSummary", code: 3, userInfo: nil)
        }

        let merged = partSummaries.enumerated().map { offset, text in
            "Part \(offset + 1): \(text)"
        }.joined(separator: "\n")

        let prompt = """
        Chapter starts at \(ChapterTitleGenerator.formatTime(startTime)).
        Summaries of sequential parts:

        \(merged)

        Reply in exactly this format:
        Title: <4–7 word chapter title>
        Summary: <one clear sentence about the whole chapter>
        """
        let response = try await session.respond(to: prompt)
        let beat = try parseTitleAndSummary(response.content)
        return (beat, true)
    }

    @available(iOS 26, *)
    private func chapterBeatFromChunks(
        transcript: String,
        startTime: TimeInterval,
        session: LanguageModelSession
    ) async throws -> ChapterBeatPlan {
        let chunks = splitTranscriptIntoChunks(transcript, maxSize: Self.chunkTranscriptCharacters)
        var partSummaries: [String] = []

        for (index, chunk) in chunks.enumerated() {
            let prompt = """
            Part \(index + 1) of \(chunks.count) (chapter starts \(ChapterTitleGenerator.formatTime(startTime))):

            \(chunk)

            Write exactly one sentence summarizing this part.
            """
            let response = try await session.respond(to: prompt, generating: ChunkSummaryPlan.self)
            let part = response.content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            partSummaries.append(part)
        }

        guard !partSummaries.isEmpty else {
            throw NSError(domain: "TranscriptSummary", code: 3, userInfo: nil)
        }

        let merged = partSummaries.enumerated().map { offset, text in
            "Part \(offset + 1): \(text)"
        }.joined(separator: "\n")

        let prompt = """
        Chapter starts at \(ChapterTitleGenerator.formatTime(startTime)).
        Summaries of sequential parts:

        \(merged)

        Write one clear sentence summary of the whole chapter and a 4–7 word title.
        """
        let response = try await session.respond(to: prompt, generating: ChapterBeatPlan.self)
        return response.content
    }

    @available(iOS 26, *)
    private func chapterBeatInstructions(episodeTitle: String) -> String {
        """
        You summarize podcast chapters and write concise titles.
        Focus on the story beat, topic, or scene — not filler words or table talk.
        Name specific topics, people, products, or events when present.
        Podcast: "\(episodeTitle)"
        """
    }

    private func chapterBeatPrompt(transcript: String, startTime: TimeInterval) -> String {
        """
        Chapter starts at \(ChapterTitleGenerator.formatTime(startTime)):

        \(transcript)

        Write one clear sentence summary and a 4–7 word chapter title.
        """
    }

    private func chapterBeatPermissivePrompt(transcript: String, startTime: TimeInterval) -> String {
        """
        Chapter starts at \(ChapterTitleGenerator.formatTime(startTime)):

        \(transcript)

        Reply in exactly this format:
        Title: <4–7 word chapter title>
        Summary: <one clear sentence>
        """
    }

    private func parseTitleAndSummary(_ text: String) throws -> ChapterBeat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !looksLikeModelRefusal(trimmed) else {
            throw NSError(domain: "TranscriptSummary", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Permissive model returned empty or refused."
            ])
        }

        var title = ""
        var summary = ""
        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            if lower.hasPrefix("title:") {
                title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if lower.hasPrefix("summary:") {
                summary = String(line.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if title.isEmpty || summary.isEmpty {
            // Single-block fallback: first line title-ish, rest summary.
            let lines = trimmed.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if title.isEmpty, let first = lines.first {
                title = first.replacingOccurrences(of: #"^Title:\s*"#, with: "", options: .regularExpression)
            }
            if summary.isEmpty {
                let rest = lines.dropFirst().joined(separator: " ")
                    .replacingOccurrences(of: #"^Summary:\s*"#, with: "", options: .regularExpression)
                summary = rest.isEmpty ? trimmed : rest
            }
        }

        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsableBeatSummary(summary), !title.isEmpty else {
            throw NSError(domain: "TranscriptSummary", code: 2, userInfo: nil)
        }
        return ChapterBeat(summary: summary, title: title)
    }

    private func looksLikeModelRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("sorry") { return true }
        if lower.contains("i can't help") || lower.contains("i cannot help") { return true }
        if lower.contains("i can't assist") || lower.contains("i cannot assist") { return true }
        if lower.contains("i'm not able to") || lower.contains("i am not able to") { return true }
        return false
    }

    @available(iOS 26, *)
    private func overviewWithModel(
        summaries: [(TimeInterval, String)],
        episodeTitle: String
    ) async throws -> String {
        let beatList = summaries
            .map { start, summary in
                "- \(ChapterTitleGenerator.formatTime(start)): \(summary)"
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

    // MARK: - Recap helpers

    private struct RecapBuildResult {
        let beatLines: [String]
        let beatSummaries: [String]
        let completedCount: Int
        let skippedEmpty: Int
        let cappedCount: Int
        let inProgressTitle: String?
        let inProgressRange: String?
        let partialSummary: String?
        let partialExcerptPreview: String?
    }

    private func buildRecapInput(
        chapters: [Chapter],
        segments: [TranscriptSegment],
        currentTime: TimeInterval,
        episodeTitle: String
    ) async -> RecapBuildResult {
        guard !chapters.isEmpty else {
            return RecapBuildResult(
                beatLines: [],
                beatSummaries: [],
                completedCount: 0,
                skippedEmpty: 0,
                cappedCount: 0,
                inProgressTitle: nil,
                inProgressRange: nil,
                partialSummary: nil,
                partialExcerptPreview: nil
            )
        }

        let completed = chapters.filter { $0.endTime <= currentTime }
        let usableCompleted = completed.filter { isUsableBeatSummary($0.summary ?? "") }
        let skippedEmpty = completed.count - usableCompleted.count
        let totalChars = usableCompleted.reduce(0) { $0 + ($1.summary?.count ?? 0) }
        let selected = selectChaptersForRecap(from: usableCompleted)
        let cappedCount = totalChars > Self.maxBeatInputCharacters ? selected.count : 0

        var lines: [String] = []
        var summaries: [String] = []
        for chapter in selected {
            let summary = chapter.summary ?? ""
            lines.append("\(ChapterTitleGenerator.formatTime(chapter.startTime)) \(chapter.title): \(summary)")
            summaries.append(summary)
        }

        var inProgressTitle: String?
        var inProgressRange: String?
        var partialSummary: String?
        var partialExcerptPreview: String?

        if let inProgress = chapters.first(where: { $0.startTime <= currentTime && $0.endTime > currentTime }) {
            inProgressTitle = inProgress.title
            inProgressRange = "\(ChapterTitleGenerator.formatTime(inProgress.startTime))–\(ChapterTitleGenerator.formatTime(currentTime))"
            let timeline = TranscriptTimeline(segments: segments)
            let heard = timeline.heardText(from: inProgress.startTime, to: currentTime)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if heard.count > 20 {
                let excerpt = cappedExcerpt(heard, maxCharacters: Self.maxPartialHeardCharacters)
                partialExcerptPreview = String(excerpt.prefix(400))
                if excerpt.count > 400 { partialExcerptPreview? += "…" }
                partialSummary = await summarizeHeardPortion(
                    excerpt: excerpt,
                    rangeLabel: inProgressRange ?? "",
                    episodeTitle: episodeTitle
                )
                if let partialSummary {
                    lines.append("\(ChapterTitleGenerator.formatTime(inProgress.startTime)) \(inProgress.title) (in progress): \(partialSummary)")
                    summaries.append(partialSummary)
                }
            }
        }

        return RecapBuildResult(
            beatLines: lines,
            beatSummaries: summaries,
            completedCount: completed.count,
            skippedEmpty: skippedEmpty,
            cappedCount: cappedCount,
            inProgressTitle: inProgressTitle,
            inProgressRange: inProgressRange,
            partialSummary: partialSummary,
            partialExcerptPreview: partialExcerptPreview
        )
    }

    private func selectChaptersForRecap(from completedChapters: [Chapter]) -> [Chapter] {
        guard !completedChapters.isEmpty else { return [] }

        let totalChars = completedChapters.reduce(0) { $0 + ($1.summary?.count ?? 0) }
        if totalChars <= Self.maxBeatInputCharacters {
            return completedChapters
        }
        return storySoFarChapters(from: completedChapters)
    }

    private func directRecap(from beatSummaries: [String]) -> String {
        return firstSentences(in: beatSummaries.joined(separator: " "), max: Self.maxRecapSentences)
    }

    @available(iOS 26, *)
    private func partialChapterSummaryWithModel(
        excerpt: String,
        rangeLabel: String,
        episodeTitle: String
    ) async throws -> String {
        let session = LanguageModelSession(instructions: """
        Summarize only what appears in the transcript excerpt below.
        Write exactly one clear sentence naming the specific topic discussed.
        Do not speculate beyond the excerpt. Podcast: "\(episodeTitle)"
        """)
        let response = try await session.respond(
            to: "Heard portion (\(rangeLabel)):\n\n\(excerpt)\n\nWrite one sentence.",
            generating: ChunkSummaryPlan.self
        )
        let summary = response.content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsableBeatSummary(summary) else {
            throw NSError(domain: "TranscriptSummary", code: 4, userInfo: nil)
        }
        return summary
    }

    @available(iOS 26, *)
    private struct CompressRecapResult {
        let text: String
        let raw: String
    }

    @available(iOS 26, *)
    private func compressBeatsToRecap(
        beatLines: [String],
        episodeTitle: String,
        currentTime: TimeInterval
    ) async throws -> CompressRecapResult {
        let beatList = beatLines.map { "- \($0)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
        You write a "story so far" recap for someone who paused a podcast mid-episode.
        Compress the chapter summaries below into exactly 2–4 short sentences.
        Present events in chronological order. Cover only what appears in the chapter list.
        Do not add topics, names, or events not mentioned in the list.
        Be specific when the summaries name topics, people, or events. No bullet points.
        Podcast: "\(episodeTitle)"
        """)
        session.prewarm()

        let prompt = "Chapters heard so far (through \(ChapterTitleGenerator.formatTime(currentTime))):\n\(beatList)\n\nWrite the story so far in 2–4 sentences."
        let response = try await session.respond(
            to: prompt,
            generating: StorySoFarPlan.self
        )
        let raw = response.content.storySoFar.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = firstSentences(in: raw, max: Self.maxRecapSentences)
        guard !text.isEmpty else {
            throw NSError(domain: "TranscriptSummary", code: 5, userInfo: nil)
        }
        return CompressRecapResult(text: text, raw: raw)
    }

    private func summarizeHeardPortion(
        excerpt: String,
        rangeLabel: String,
        episodeTitle: String
    ) async -> String? {
        if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
            do {
                return try await partialChapterSummaryWithModel(
                    excerpt: excerpt,
                    rangeLabel: rangeLabel,
                    episodeTitle: episodeTitle
                )
            } catch {
                logger.warning("Partial chapter recap failed: \(error.localizedDescription)")
            }
        }
        return nil
    }

    private func lexicalRecapFallback(from beatSummaries: [String]) -> String {
        let summaries = beatSummaries.suffix(3)
        return firstSentences(in: summaries.joined(separator: " "), max: Self.maxRecapSentences)
    }

    private func storySoFarChapters(from completedChapters: [Chapter]) -> [Chapter] {
        guard completedChapters.count > Self.storySoFarBeatLimit else { return completedChapters }
        return Array(completedChapters.suffix(Self.storySoFarBeatLimit))
    }

    private func isUsableBeatSummary(_ summary: String) -> Bool {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count <= Self.maxUsableBeatSummaryCharacters else { return false }
        if trimmed.contains(" … ") { return false }
        if trimmed.hasPrefix("…") { return false }
        return true
    }

    private func splitTranscriptIntoChunks(_ text: String, maxSize: Int) -> [String] {
        guard text.count > maxSize else { return [text] }

        var chunks: [String] = []
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            if remaining.count <= maxSize {
                chunks.append(String(remaining))
                break
            }
            let sliceEnd = remaining.index(remaining.startIndex, offsetBy: maxSize)
            var breakIndex = sliceEnd
            if let lastSpace = remaining[..<sliceEnd].lastIndex(of: " ") {
                breakIndex = lastSpace
            }
            let chunk = String(remaining[..<breakIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            let nextStart = remaining.index(after: breakIndex)
            remaining = remaining[nextStart...]
        }

        return chunks.isEmpty ? [text] : chunks
    }

    private func cappedExcerpt(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let prefix = String(text.prefix(maxCharacters))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return prefix + "…"
    }

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
                if !sentence.isEmpty { sentences.append(sentence) }
                buffer = ""
                if sentences.count >= max { break }
            }
        }

        if sentences.count < max {
            let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { sentences.append(tail) }
        }

        return sentences.prefix(max).joined(separator: " ")
    }

}

@available(iOS 26, *)
@Generable
private struct ChapterBeatPlan {
    @Guide(description: "One clear sentence summarizing the chapter topic or story beat.")
    var summary: String
    @Guide(description: "Concise chapter title, 4–7 words.")
    var title: String
}

@available(iOS 26, *)
@Generable
private struct ChunkSummaryPlan {
    @Guide(description: "Exactly one sentence summary.")
    var summary: String
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
    @Guide(description: "Exactly 2–4 short sentences on what the listener has heard so far.")
    var storySoFar: String
}
