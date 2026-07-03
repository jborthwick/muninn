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

        let contextText = recapContext(
            from: start,
            to: currentTime,
            segments: segments
        )
        guard !contextText.isEmpty else { return }

        if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
            do {
                pauseRecap = try await recapWithModel(
                    context: contextText,
                    episodeTitle: episode.title,
                    windowMinutes: windowMinutes
                )
                return
            } catch {
                logger.warning("Pause recap failed: \(error.localizedDescription)")
            }
        }

        pauseRecap = String(contextText.prefix(280)).trimmingCharacters(in: .whitespacesAndNewlines)
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
        context: String,
        episodeTitle: String,
        windowMinutes: Int
    ) async throws -> String {
        let session = LanguageModelSession(instructions: """
        Summarize what just happened in a podcast in 2–4 short sentences.
        Be specific to the content; write for someone who paused mid-episode.
        Podcast: "\(episodeTitle)"
        """)

        let response = try await session.respond(
            to: "Summarize the last \(windowMinutes) minutes:\n\n\(context)",
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

    private func recapContext(
        from start: TimeInterval,
        to end: TimeInterval,
        segments: [TranscriptSegment]
    ) -> String {
        if let beats = summary?.beats, !beats.isEmpty {
            let relevant = beats.filter { $0.endTime > start && $0.startTime < end }
            if !relevant.isEmpty {
                return relevant.map(\.summary).joined(separator: " ")
            }
        }

        return segments
            .filter { $0.endTime > start && $0.startTime < end }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    @Guide(description: "2–4 sentence recap of recent content.")
    var recap: String
}
