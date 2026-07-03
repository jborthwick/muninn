import Foundation
import FoundationModels
import os

/// Builds chapter excerpts and generates titles via Foundation Models with lexical fallback.
enum ChapterTitleGenerator {
    struct SegmentDraft {
        let startTime: TimeInterval
        let excerpt: String
    }

    private static let logger = Logger(subsystem: "com.muninn", category: "ChapterTitles")

    // MARK: - Excerpt

    static func excerpt(from segments: [TranscriptSegment], budget: Int = 600) -> String {
        let text = segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > budget else { return text }

        let startBudget = budget * 2 / 3
        let endBudget = max(budget - startBudget - 3, 80)
        let start = String(text.prefix(startBudget))
        let midOffset = text.count / 2
        let midStart = text.index(text.startIndex, offsetBy: midOffset)
        let end = String(text[midStart...].prefix(endBudget))
        return "\(start) … \(end)"
    }

    // MARK: - Title generation

    @available(iOS 26, *)
    static func titles(
        for drafts: [SegmentDraft],
        episodeTitle: String,
        synopsis: String?,
        episodeDuration: TimeInterval = 0
    ) async -> [String] {
        guard !drafts.isEmpty else { return [] }

        if SystemLanguageModel.default.isAvailable {
            do {
                return try await generateWithModel(
                    drafts: drafts,
                    episodeTitle: episodeTitle,
                    synopsis: synopsis,
                    episodeDuration: episodeDuration
                )
            } catch {
                logger.warning("Primary chapter title generation failed: \(error.localizedDescription)")
            }
            do {
                return try await generateMetadataOnly(
                    drafts: drafts,
                    episodeTitle: episodeTitle,
                    synopsis: synopsis,
                    episodeDuration: episodeDuration
                )
            } catch {
                logger.error("Metadata-only chapter title generation failed: \(error.localizedDescription)")
            }
        } else {
            logger.info("System language model unavailable; using lexical chapter titles")
        }

        return drafts.enumerated().map { index, draft in
            titleForDraft(
                draft,
                index: index,
                draftCount: drafts.count,
                episodeDuration: episodeDuration
            )
        }
    }

    @available(iOS 26, *)
    private static func generateWithModel(
        drafts: [SegmentDraft],
        episodeTitle: String,
        synopsis: String?,
        episodeDuration: TimeInterval
    ) async throws -> [String] {
        let instructions = instructionsBlock(episodeTitle: episodeTitle, synopsis: synopsis)
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()

        let prompt = promptBlock(drafts: drafts, includeExcerpts: true)
        let response = try await session.respond(to: prompt, generating: ChapterTitlePlan.self)
        return normalizedTitles(
            response.content.titles,
            drafts: drafts,
            episodeDuration: episodeDuration
        )
    }

    @available(iOS 26, *)
    private static func generateMetadataOnly(
        drafts: [SegmentDraft],
        episodeTitle: String,
        synopsis: String?,
        episodeDuration: TimeInterval
    ) async throws -> [String] {
        let instructions = instructionsBlock(episodeTitle: episodeTitle, synopsis: synopsis)
        let session = LanguageModelSession(instructions: instructions)

        let prompt = promptBlock(drafts: drafts, includeExcerpts: false)
        let response = try await session.respond(to: prompt, generating: ChapterTitlePlan.self)
        return normalizedTitles(
            response.content.titles,
            drafts: drafts,
            episodeDuration: episodeDuration
        )
    }

    @available(iOS 26, *)
    private static func instructionsBlock(episodeTitle: String, synopsis: String?) -> String {
        var block = """
        You write concise podcast chapter titles (4–7 words).
        Be specific to what is discussed; summarize the scene or topic in plain language.
        Avoid filler labels like Discussion or Wrap-up.
        For supporter roll calls or closing credits, use Closing Credits or Supporter Thanks.
        Podcast: "\(episodeTitle)"
        """
        if let synopsis, !synopsis.isEmpty {
            block += "\nEpisode synopsis: \(synopsis)"
        }
        return block
    }

    private static func promptBlock(drafts: [SegmentDraft], includeExcerpts: Bool) -> String {
        let segments = drafts.enumerated().map { index, draft -> String in
            let header = "Segment \(index + 1) (starts \(formatTime(draft.startTime))):"
            if isRollCallLike(draft.excerpt) {
                return "\(header)\nMostly a supporter roll call or closing credits."
            }
            if includeExcerpts {
                return "\(header)\n\(draft.excerpt)"
            }
            let keywords = topKeywords(in: draft.excerpt, limit: 6).joined(separator: ", ")
            return "\(header)\nKeywords: \(keywords)"
        }.joined(separator: "\n\n")

        return """
        Write exactly one chapter title per segment below, in the same order.
        Return \(drafts.count) titles.

        \(segments)
        """
    }

    private static func normalizedTitles(
        _ raw: [String],
        drafts: [SegmentDraft],
        episodeDuration: TimeInterval
    ) -> [String] {
        drafts.indices.map { index in
            let draft = drafts[index]
            if isRollCallLike(draft.excerpt) {
                return rollCallTitle(
                    for: draft,
                    index: index,
                    draftCount: drafts.count,
                    episodeDuration: episodeDuration
                )
            }
            let candidate = index < raw.count ? raw[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !candidate.isEmpty {
                return candidate
            }
            return lexicalTitle(from: draft.excerpt, startTime: draft.startTime)
        }
    }

    private static func titleForDraft(
        _ draft: SegmentDraft,
        index: Int,
        draftCount: Int,
        episodeDuration: TimeInterval
    ) -> String {
        if isRollCallLike(draft.excerpt) {
            return rollCallTitle(for: draft, index: index, draftCount: draftCount, episodeDuration: episodeDuration)
        }
        return lexicalTitle(from: draft.excerpt, startTime: draft.startTime)
    }

    /// Name lists and credits: many unique tokens, little connective language.
    static func isRollCallLike(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("patreon") || lower.contains("shout-out") || lower.contains("shout out") {
            return true
        }

        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard words.count >= 16 else { return false }

        let uniqueRatio = Double(Set(words.map { $0.lowercased() }).count) / Double(words.count)
        let stopCount = words.filter { stopWords.contains($0.lowercased()) }.count
        let stopRatio = Double(stopCount) / Double(words.count)

        return uniqueRatio > 0.78 && stopRatio < 0.08
    }

    private static func rollCallTitle(
        for draft: SegmentDraft,
        index: Int,
        draftCount: Int,
        episodeDuration: TimeInterval
    ) -> String {
        let inFinalStretch = episodeDuration > 0 && draft.startTime >= episodeDuration * 0.8
        let isLast = index >= draftCount - 1
        if isLast && inFinalStretch { return "Closing Credits" }
        if inFinalStretch { return "Supporter Thanks" }
        return "Supporter Shoutouts"
    }

    // MARK: - Lexical fallback

    static func lexicalTitle(from text: String, startTime: TimeInterval) -> String {
        let keywords = topKeywords(in: text, limit: 3)
        if !keywords.isEmpty {
            return keywords.map { $0.capitalized }.joined(separator: " ")
        }
        return "At \(formatTime(startTime))"
    }

    static func topKeywords(in text: String, limit: Int) -> [String] {
        var frequency: [String: Int] = [:]
        var order: [String] = []

        for word in text.lowercased().components(separatedBy: .whitespacesAndNewlines) {
            let w = word.trimmingCharacters(in: .punctuationCharacters)
            guard w.count > 3, !stopWords.contains(w) else { continue }
            if frequency[w] == nil { order.append(w) }
            frequency[w, default: 0] += 1
        }

        return order
            .sorted { (frequency[$0] ?? 0) > (frequency[$1] ?? 0) }
            .prefix(limit)
            .map { $0 }
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with",
        "is", "it", "that", "this", "was", "are", "be", "been", "have", "has", "had",
        "do", "did", "will", "would", "could", "should", "may", "i", "you", "we", "they",
        "he", "she", "so", "my", "your", "like", "just", "know", "think", "yeah", "um", "uh",
        "its", "we're", "i'm", "you're", "they're", "don't", "can't", "won't", "isn't",
        "about", "really", "going", "thing", "things", "there", "what", "when", "where",
    ]
}

@available(iOS 26, *)
@Generable
private struct ChapterTitlePlan {
    @Guide(description: "Chapter titles in segment order. One title per segment; 4–7 words each.")
    var titles: [String]
}
