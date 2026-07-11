import Foundation

/// Lexical helpers for chapter excerpts and roll-call detection.
enum ChapterTitleGenerator {
    struct SegmentDraft {
        let startTime: TimeInterval
        /// Short excerpt for lexical title fallback only.
        let excerpt: String
        /// Full chapter transcript for summary generation.
        let transcript: String
        var summary: String?
    }

    // MARK: - Excerpt

    static func fullTranscript(from segments: [TranscriptSegment]) -> String {
        segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func excerpt(from segments: [TranscriptSegment], budget: Int = 600) -> String {
        let text = fullTranscript(from: segments)
        guard text.count > budget else { return text }

        let startBudget = budget * 2 / 3
        let endBudget = max(budget - startBudget - 3, 80)
        let start = String(text.prefix(startBudget))
        let midOffset = text.count / 2
        let midStart = text.index(text.startIndex, offsetBy: midOffset)
        let end = String(text[midStart...].prefix(endBudget))
        return "\(start) … \(end)"
    }

    // MARK: - Lexical fallback

    static func lexicalTitle(from text: String, startTime: TimeInterval) -> String {
        let keywords = topKeywords(in: text, limit: 3)
        if !keywords.isEmpty {
            return keywords.map { $0.capitalized }.joined(separator: " ")
        }
        return "At \(formatTime(startTime))"
    }

    static func rollCallTitle(
        startTime: TimeInterval,
        index: Int,
        draftCount: Int,
        episodeDuration: TimeInterval
    ) -> String {
        let inFinalStretch = episodeDuration > 0 && startTime >= episodeDuration * 0.8
        let isLast = index >= draftCount - 1
        if isLast && inFinalStretch { return "Closing Credits" }
        if inFinalStretch { return "Supporter Thanks" }
        return "Supporter Shoutouts"
    }

    static func rollCallSummary() -> String {
        "Supporter roll call or closing credits."
    }

    /// Name-list chapters in the closing stretch — statistical only, no phrase matching.
    static func isRollCallLike(
        _ text: String,
        startTime: TimeInterval = 0,
        episodeDuration: TimeInterval = 0
    ) -> Bool {
        let inFinalStretch = episodeDuration > 0 && startTime >= episodeDuration * 0.8
        guard inFinalStretch else { return false }
        return hasNameListShape(text)
    }

    /// Long stretches of mostly unique short tokens — typical of name lists, not conversation.
    private static func hasNameListShape(_ text: String) -> Bool {
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard words.count >= 50 else { return false }

        let lowered = words.map { $0.lowercased() }
        let uniqueRatio = Double(Set(lowered).count) / Double(words.count)
        let stopRatio = Double(lowered.filter { stopWords.contains($0) }.count) / Double(words.count)
        guard uniqueRatio > 0.88, stopRatio < 0.05 else { return false }

        let shortRatio = Double(words.filter { $0.count <= 10 }.count) / Double(words.count)
        var frequency: [String: Int] = [:]
        for word in lowered { frequency[word, default: 0] += 1 }
        let hapaxRatio = Double(frequency.values.filter { $0 == 1 }.count) / Double(words.count)

        return shortRatio > 0.75 && hapaxRatio > 0.72
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
