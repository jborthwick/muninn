import Foundation
import FoundationModels
import SwiftData
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

    private(set) var summary: EpisodeSummary?
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
    /// Keep all completed beats when their combined text fits this budget.
    private static let maxBeatInputCharacters = 2_800
    private static let directJoinBeatLimit = 4

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
        beats: [SummaryBeat],
        episodeTitle: String
    ) async -> (text: String, error: String?) {
        guard !beats.isEmpty else { return ("", nil) }

        if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
            do {
                let text = try await overviewWithModel(beats: beats, episodeTitle: episodeTitle)
                return (text, nil)
            } catch {
                logger.warning("Overview generation failed: \(error.localizedDescription)")
                let fallback = beats.map(\.summary).filter { !$0.isEmpty }.joined(separator: " ")
                return (fallback, error.localizedDescription)
            }
        }

        let fallback = beats.map(\.summary).filter { !$0.isEmpty }.joined(separator: " ")
        return (fallback, nil)
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

    func generatePauseRecap(
        episode: Episode,
        segments: [TranscriptSegment],
        currentTime: TimeInterval
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

        if summary == nil {
            load(for: episode)
        }

        debug.totalBeatCount = summary?.beats.count ?? 0

        let build = await buildRecapInput(
            summary: summary,
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
                    source: "foundation_model",
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
    }

    @available(iOS 26, *)
    private func chapterBeatWithModel(
        transcript: String,
        startTime: TimeInterval,
        episodeTitle: String
    ) async throws -> ChapterModelResult {
        let instructions = chapterBeatInstructions(episodeTitle: episodeTitle)
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "TranscriptSummary", code: 1, userInfo: nil)
        }

        let plan: ChapterBeatPlan
        let usedChunking: Bool
        if trimmed.count <= Self.maxChapterTranscriptCharacters {
            let prompt = chapterBeatPrompt(transcript: trimmed, startTime: startTime)
            let response = try await session.respond(to: prompt, generating: ChapterBeatPlan.self)
            plan = response.content
            usedChunking = false
        } else {
            plan = try await chapterBeatFromChunks(
                transcript: trimmed,
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
        return ChapterModelResult(beat: ChapterBeat(summary: summary, title: title), usedChunking: usedChunking)
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

    @available(iOS 26, *)
    private func overviewWithModel(beats: [SummaryBeat], episodeTitle: String) async throws -> String {
        let beatList = beats
            .filter { !$0.summary.isEmpty }
            .map { beat in
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
        summary: EpisodeSummary?,
        segments: [TranscriptSegment],
        currentTime: TimeInterval,
        episodeTitle: String
    ) async -> RecapBuildResult {
        guard let beats = summary?.beats, !beats.isEmpty else {
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

        let completed = beats.filter { $0.endTime <= currentTime }
        let usableCompleted = completed.filter { isUsableBeatSummary($0.summary) }
        let skippedEmpty = completed.count - usableCompleted.count
        let totalChars = usableCompleted.reduce(0) { $0 + $1.summary.count }
        let selected = selectBeatsForRecap(from: usableCompleted)
        let cappedCount = totalChars > Self.maxBeatInputCharacters ? selected.count : 0

        var lines: [String] = []
        var summaries: [String] = []
        for beat in selected {
            let label = beat.title.flatMap { !$0.isEmpty ? $0 : nil } ?? "Chapter"
            lines.append("\(ChapterTitleGenerator.formatTime(beat.startTime)) \(label): \(beat.summary)")
            summaries.append(beat.summary)
        }

        var inProgressTitle: String?
        var inProgressRange: String?
        var partialSummary: String?
        var partialExcerptPreview: String?

        if let inProgress = beats.first(where: { $0.startTime <= currentTime && $0.endTime > currentTime }) {
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
                    let label = inProgress.title.flatMap { !$0.isEmpty ? $0 : nil } ?? "Current chapter"
                    lines.append("\(ChapterTitleGenerator.formatTime(inProgress.startTime)) \(label) (in progress): \(partialSummary)")
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

    private func selectBeatsForRecap(from completedBeats: [SummaryBeat]) -> [SummaryBeat] {
        guard !completedBeats.isEmpty else { return [] }

        let totalChars = completedBeats.reduce(0) { $0 + $1.summary.count }
        if totalChars <= Self.maxBeatInputCharacters {
            return completedBeats
        }
        return storySoFarBeats(from: completedBeats)
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

    private func storySoFarBeats(from completedBeats: [SummaryBeat]) -> [SummaryBeat] {
        guard completedBeats.count > Self.storySoFarBeatLimit else { return completedBeats }
        return Array(completedBeats.suffix(Self.storySoFarBeatLimit))
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
