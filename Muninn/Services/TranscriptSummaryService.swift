import Foundation
import FoundationModels
import UIKit
import os

struct ChapterBeat: Equatable, Sendable {
    let summary: String
    let title: String
}

struct ChapterBeatsResult: Equatable {
    let beats: [ChapterBeat]
    let entries: [ChapterBeatDebugEntry]
}

/// Thrown when on-device chapter generation should stop and retry later
/// (app backgrounded / locked, or the generation task was cancelled).
enum OnDeviceGenerationInterrupt: Error, Equatable {
    case backgroundUnavailable
    case cancelled
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

    /// On-device model context is ~4096 tokens (~3–4 Latin chars/token). Leave headroom
    /// for instructions, framing, and the response — never reuse a session across chunks.
    private static let maxChapterTranscriptCharacters = 3_500
    private static let chunkTranscriptCharacters = 3_000
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
    ) async throws -> ChapterBeatsResult {
        guard !drafts.isEmpty else { return ChapterBeatsResult(beats: [], entries: []) }

        var beats: [ChapterBeat] = []
        var entries: [ChapterBeatDebugEntry] = []
        for (index, draft) in drafts.enumerated() {
            try checkOnDeviceGenerationStillAllowed()
            let result = try await generateSingleChapterBeat(
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

        if SystemLanguageModel.default.isAvailable {
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

        if SystemLanguageModel.default.isAvailable {
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
    ) async throws -> (beat: ChapterBeat, entry: ChapterBeatDebugEntry) {
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

        if SystemLanguageModel.default.isAvailable {
            do {
                try checkOnDeviceGenerationStillAllowed()
                let modelResult = try await chapterBeatWithModel(
                    transcript: draft.transcript,
                    startTime: draft.startTime,
                    episodeTitle: episodeTitle
                )
                try checkOnDeviceGenerationStillAllowed()
                return entry(
                    beat: modelResult.beat,
                    source: modelResult.usedPermissiveFallback
                        ? "foundation_model_permissive"
                        : "foundation_model",
                    flaggedRollCall: false,
                    usedChunking: modelResult.usedChunking,
                    error: nil
                )
            } catch is CancellationError {
                throw OnDeviceGenerationInterrupt.cancelled
            } catch let interrupt as OnDeviceGenerationInterrupt {
                throw interrupt
            } catch {
                // Locking/backgrounding often surfaces as model failures. Abort so we
                // retry in the foreground instead of persisting empty lexical stubs.
                if Self.shouldAbortModelFailure() {
                    logger.warning(
                        "Chapter beat generation interrupted in background: \(error.localizedDescription)"
                    )
                    throw OnDeviceGenerationInterrupt.backgroundUnavailable
                }
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

        // Model unavailable while inactive is often temporary (locked / suspended).
        if Self.shouldAbortModelFailure() {
            throw OnDeviceGenerationInterrupt.backgroundUnavailable
        }

        let beat = ChapterBeat(
            summary: "",
            title: ChapterTitleGenerator.lexicalTitle(from: draft.excerpt, startTime: draft.startTime)
        )
        return entry(beat: beat, source: "lexical_fallback", flaggedRollCall: false, usedChunking: false, error: nil)
    }

    private func checkOnDeviceGenerationStillAllowed() throws {
        if Task.isCancelled {
            throw OnDeviceGenerationInterrupt.cancelled
        }
        if Self.shouldAbortModelFailure() {
            throw OnDeviceGenerationInterrupt.backgroundUnavailable
        }
    }

    /// When inactive/backgrounded, Foundation Models are unreliable — prefer retry over lexical stubs.
    private static func shouldAbortModelFailure() -> Bool {
        UIApplication.shared.applicationState != .active
    }

    private func debugExcerptPreview(_ text: String, limit: Int = 240) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    private struct ChapterModelResult {
        let beat: ChapterBeat
        let usedChunking: Bool
        let usedPermissiveFallback: Bool
    }

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

    private func chapterBeatWithGuidedGeneration(
        transcript: String,
        startTime: TimeInterval,
        episodeTitle: String
    ) async throws -> (beat: ChapterBeat, usedChunking: Bool) {
        let plan: ChapterBeatPlan
        let usedChunking: Bool
        if transcript.count <= Self.maxChapterTranscriptCharacters {
            let session = makeChapterSession(episodeTitle: episodeTitle, permissive: false)
            let prompt = chapterBeatPrompt(transcript: transcript, startTime: startTime)
            let response = try await session.respond(to: prompt, generating: ChapterBeatPlan.self)
            plan = response.content
            usedChunking = false
        } else {
            plan = try await chapterBeatFromChunks(
                transcript: transcript,
                startTime: startTime,
                episodeTitle: episodeTitle,
                permissive: false
            )
            usedChunking = true
        }

        let title = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let summary = normalizeBeatSummary(plan.summary) else {
            throw NSError(domain: "TranscriptSummary", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Model returned an unusable chapter summary."
            ])
        }
        let cleaned = sanitizeTitle(title)
        let finalTitle = isUsableChapterTitle(cleaned)
            ? cleaned
            : ChapterTitleGenerator.lexicalTitle(from: summary, startTime: startTime)
        return (ChapterBeat(summary: summary, title: finalTitle), usedChunking)
    }

    private func chapterBeatWithPermissiveString(
        transcript: String,
        startTime: TimeInterval,
        episodeTitle: String
    ) async throws -> (beat: ChapterBeat, usedChunking: Bool) {
        if transcript.count <= Self.maxChapterTranscriptCharacters {
            let session = makeChapterSession(episodeTitle: episodeTitle, permissive: true)
            let prompt = chapterBeatPermissivePrompt(transcript: transcript, startTime: startTime)
            let response = try await session.respond(to: prompt)
            let beat = try parseTitleAndSummary(response.content, startTime: startTime)
            return (beat, false)
        }

        let plan = try await chapterBeatFromChunks(
            transcript: transcript,
            startTime: startTime,
            episodeTitle: episodeTitle,
            permissive: true
        )
        let cleaned = sanitizeTitle(plan.title)
        guard let summary = normalizeBeatSummary(plan.summary) else {
            throw NSError(domain: "TranscriptSummary", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not parse a usable chapter summary from the model."
            ])
        }
        let finalTitle = isUsableChapterTitle(cleaned)
            ? cleaned
            : ChapterTitleGenerator.lexicalTitle(from: summary, startTime: startTime)
        return (ChapterBeat(summary: summary, title: finalTitle), true)
    }

    private func chapterBeatFromChunks(
        transcript: String,
        startTime: TimeInterval,
        episodeTitle: String,
        permissive: Bool
    ) async throws -> ChapterBeatPlan {
        let chunks = splitTranscriptIntoChunks(transcript, maxSize: Self.chunkTranscriptCharacters)
        var partSummaries: [String] = []

        for (index, chunk) in chunks.enumerated() {
            // Fresh session per chunk — prior turns would exhaust the 4k context window.
            let session = makeChapterSession(episodeTitle: episodeTitle, permissive: permissive)
            let prompt = """
            Part \(index + 1) of \(chunks.count) (chapter starts \(ChapterTitleGenerator.formatTime(startTime))):

            \(chunk)

            Write exactly one sentence summarizing this part.
            """
            if permissive {
                let response = try await session.respond(to: prompt)
                let part = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !part.isEmpty, !looksLikeModelRefusal(part) else { continue }
                partSummaries.append(part)
            } else {
                let response = try await session.respond(to: prompt, generating: ChunkSummaryPlan.self)
                let part = response.content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !part.isEmpty else { continue }
                partSummaries.append(part)
            }
        }

        guard !partSummaries.isEmpty else {
            throw NSError(domain: "TranscriptSummary", code: 3, userInfo: nil)
        }

        let merged = partSummaries.enumerated().map { offset, text in
            "Part \(offset + 1): \(text)"
        }.joined(separator: "\n")

        let mergeSession = makeChapterSession(episodeTitle: episodeTitle, permissive: permissive)
        if permissive {
            let prompt = """
            These are sequential parts of ONE chapter that starts at \(ChapterTitleGenerator.formatTime(startTime)):

            \(merged)

            Write a short topic title and one-sentence summary for this whole chapter.
            Start line 1 with "Title:" and line 2 with "Summary:".
            Use your own words. Do not number the chapter.
            """
            let response = try await mergeSession.respond(to: prompt)
            let beat = try parseTitleAndSummary(response.content, startTime: startTime)
            return ChapterBeatPlan(summary: beat.summary, title: beat.title)
        }

        let prompt = """
        These are sequential parts of ONE chapter that starts at \(ChapterTitleGenerator.formatTime(startTime)):

        \(merged)

        Write one clear sentence summary of this whole chapter and a 4–7 word title.
        Do not number the chapter. Do not mention the podcast title.
        """
        let response = try await mergeSession.respond(to: prompt, generating: ChapterBeatPlan.self)
        return response.content
    }

    private func makeChapterSession(episodeTitle: String, permissive: Bool) -> LanguageModelSession {
        let instructions = chapterBeatInstructions(episodeTitle: episodeTitle)
        if permissive {
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            return LanguageModelSession(model: model, instructions: instructions)
        }
        return LanguageModelSession(instructions: instructions)
    }

    private func chapterBeatInstructions(episodeTitle: String) -> String {
        """
        You summarize one podcast chapter and write a concise title for that chapter only.
        Focus on the story beat, topic, or scene — not filler words or table talk.
        Name specific topics, people, products, or events when present.
        Never write preamble, never number chapters (no "Chapter 1"), never mention the podcast title.
        Podcast context only: "\(episodeTitle)"
        """
    }

    private func chapterBeatPrompt(transcript: String, startTime: TimeInterval) -> String {
        """
        One chapter starting at \(ChapterTitleGenerator.formatTime(startTime)):

        \(transcript)

        Write one clear sentence summary and a 4–7 word chapter title for this chapter only.
        """
    }

    private func chapterBeatPermissivePrompt(transcript: String, startTime: TimeInterval) -> String {
        """
        One chapter starting at \(ChapterTitleGenerator.formatTime(startTime)):

        \(transcript)

        Write a short topic title (about 4 to 7 words) and one clear sentence summary.
        Start line 1 with "Title:" and line 2 with "Summary:".
        Use your own words from the transcript. Do not number the chapter.
        """
    }

    private func parseTitleAndSummary(_ text: String, startTime: TimeInterval = 0) throws -> ChapterBeat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !looksLikeModelRefusal(trimmed) else {
            throw NSError(domain: "TranscriptSummary", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Permissive model returned empty or refused."
            ])
        }

        var title = ""
        var summary = ""

        // Prefer labeled lines; also accept bold markdown (**Title:**) and same-line labels.
        for rawLine in trimmed.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let value = labeledValue(in: line, label: "title"), title.isEmpty {
                title = value
            }
            if let value = labeledValue(in: line, label: "summary") {
                summary = summary.isEmpty ? value : summary + " " + value
            }
        }

        // Same-line "Title: X Summary: Y"
        if summary.isEmpty, let inline = labeledValue(in: trimmed, label: "summary") {
            summary = inline
        }
        if title.isEmpty, let inline = labeledValue(in: trimmed, label: "title") {
            title = inline
        }

        // If labels were missing, use non-preamble lines — never promote chatty intros to titles.
        if title.isEmpty || summary.isEmpty {
            let contentLines = trimmed.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !looksLikeTitlePreamble($0) }
            if summary.isEmpty {
                let body = contentLines
                    .map { stripLabelPrefix($0, label: "summary") }
                    .filter { labeledValue(in: $0, label: "title") == nil }
                    .joined(separator: " ")
                if !body.isEmpty { summary = body }
            }
            if title.isEmpty {
                // Do not invent a title from freeform prose; lexical fallback after summary normalize.
                title = ""
            }
        }

        guard let normalizedSummary = normalizeBeatSummary(summary) else {
            logger.warning("Permissive parse failed usable summary. Raw: \(trimmed.prefix(400))")
            throw NSError(domain: "TranscriptSummary", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not parse a usable chapter summary from the model."
            ])
        }

        let cleanedTitle = sanitizeTitle(title)
        let finalTitle = isUsableChapterTitle(cleanedTitle)
            ? cleanedTitle
            : ChapterTitleGenerator.lexicalTitle(from: normalizedSummary, startTime: startTime)

        return ChapterBeat(summary: normalizedSummary, title: finalTitle)
    }

    private func labeledValue(in line: String, label: String) -> String? {
        let pattern = #"^\**\s*"# + NSRegularExpression.escapedPattern(for: label) + #"\**\s*:\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        var value = String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Cut trailing "Summary: …" if title and summary were on one line.
        if label == "title", let cut = value.range(of: #"\s+\**Summary\**\s*:"#, options: [.regularExpression, .caseInsensitive]) {
            value = String(value[..<cut.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "*\"'"))
        return value.isEmpty ? nil : value
    }

    private func stripLabelPrefix(_ text: String, label: String) -> String {
        if let value = labeledValue(in: text, label: label) { return value }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizeTitle(_ title: String) -> String {
        var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "*\"'#"))
        // Models often emit "Chapter 1: Real Title" — drop the bogus numbering.
        if let range = value.range(of: #"^Chapter\s+\d+\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            value = String(value[range.upperBound...])
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep titles short; models sometimes dump the summary into Title.
        if value.count > 60 {
            value = String(value.prefix(60))
            if let lastSpace = value.lastIndex(of: " ") {
                value = String(value[..<lastSpace])
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isUsableChapterTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        guard trimmed.count <= 60 else { return false }

        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard (2...10).contains(words.count) else { return false }

        if looksLikeTitlePreamble(trimmed) { return false }
        if looksLikePromptPlaceholder(trimmed) { return false }
        if trimmed.hasSuffix(":") { return false }
        if trimmed.lowercased().range(of: #"^chapter\s+\d+:?\s*$"#, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    private func looksLikePromptPlaceholder(_ text: String) -> Bool {
        let lower = text.lowercased()
        if text.contains("<") || text.contains(">") { return true }
        let stripped = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped == "…" || stripped == "..." || stripped == "title" || stripped == "summary" {
            return true
        }
        if lower.contains("4-7") || lower.contains("4–7") { return true }
        if lower.contains("word topic") || lower.contains("topic title") { return true }
        if lower.contains("word title") || lower.contains("clear sentence") { return true }
        if lower.contains("one clear") { return true }
        // Former prompt examples the model loved to echo.
        let bannedExamples = [
            "lore versus character",
            "lore vs. character",
            "lore vs character",
            "devil's advocate debate",
            "devils advocate debate"
        ]
        if bannedExamples.contains(lower) { return true }
        return false
    }

    private func looksLikeTitlePreamble(_ text: String) -> Bool {
        let lower = text.lowercased()
        let prefixes = [
            "here are", "here is", "here's", "sure,", "sure ", "okay,", "ok,",
            "of course", "i'll ", "i will ", "let me ", "below are", "the following",
            "as requested", "certainly"
        ]
        if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        if lower.contains("chapter summar") { return true }
        if lower.contains("for the podcast") { return true }
        if lower.contains("summaries for") { return true }
        return false
    }

    /// Accepts a summary, clipping to the usable budget instead of rejecting long model output.
    private func normalizeBeatSummary(_ summary: String) -> String? {
        var trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "*\"'"))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(" … ") { return nil }
        if trimmed.hasPrefix("…") { return nil }
        if looksLikeModelRefusal(trimmed) { return nil }
        if looksLikeTitlePreamble(trimmed) {
            // Strip a leading preamble sentence if a real summary follows.
            if let dot = trimmed.firstIndex(of: "."), dot < trimmed.endIndex {
                let after = trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty, !looksLikeTitlePreamble(after) {
                    trimmed = after
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
        if looksLikePromptPlaceholder(trimmed) { return nil }

        if trimmed.count > Self.maxUsableBeatSummaryCharacters {
            let clipped = firstSentences(in: trimmed, max: 1)
            if !clipped.isEmpty, clipped.count <= Self.maxUsableBeatSummaryCharacters {
                return clipped
            }
            let end = trimmed.index(trimmed.startIndex, offsetBy: Self.maxUsableBeatSummaryCharacters)
            var slice = String(trimmed[..<end])
            if let lastSpace = slice.lastIndex(of: " ") {
                slice = String(slice[..<lastSpace])
            }
            return slice.isEmpty ? nil : slice
        }
        return trimmed
    }

    private func looksLikeModelRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("sorry") { return true }
        if lower.contains("i can't help") || lower.contains("i cannot help") { return true }
        if lower.contains("i can't assist") || lower.contains("i cannot assist") { return true }
        if lower.contains("i'm not able to") || lower.contains("i am not able to") { return true }
        return false
    }

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

    private struct CompressRecapResult {
        let text: String
        let raw: String
    }

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
        if SystemLanguageModel.default.isAvailable {
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

@Generable
private struct ChapterBeatPlan {
    @Guide(description: "One clear sentence summarizing the chapter topic or story beat.")
    var summary: String
    @Guide(description: "Concise chapter title, 4–7 words.")
    var title: String
}

@Generable
private struct ChunkSummaryPlan {
    @Guide(description: "Exactly one sentence summary.")
    var summary: String
}

@Generable
private struct EpisodeOverviewPlan {
    @Guide(description: "2–3 sentence episode overview.")
    var overview: String
}

@Generable
private struct StorySoFarPlan {
    @Guide(description: "Exactly 2–4 short sentences on what the listener has heard so far.")
    var storySoFar: String
}
