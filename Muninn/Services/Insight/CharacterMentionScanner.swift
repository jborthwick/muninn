import Foundation

/// Whole-word mention detection for known character names in free text
/// (wiki prose or transcripts).
enum CharacterMentionScanner {
    /// Names from `candidates` that appear as whole words in `text`, in first-seen order.
    /// Prefer longer candidates first so "Ember Elysiana" wins over a later bare "Ember"
    /// at the same position when collapsing aliases downstream.
    static func mentions(of candidates: [String], in text: String) -> [String] {
        let foldedText = ShowWikiMapping.fold(text)
        guard !foldedText.isEmpty else { return [] }

        var hits: [(name: String, location: Int)] = []
        var seenKeys = Set<String>()

        let sorted = candidates
            .filter { $0.count > 2 }
            .sorted { $0.count > $1.count }

        for name in sorted {
            let folded = ShowWikiMapping.fold(name)
            guard folded.count > 2 else { continue }
            let key = folded
            guard !seenKeys.contains(key) else { continue }

            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: folded))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(foldedText.startIndex..., in: foldedText)
            guard let match = regex.firstMatch(in: foldedText, range: range) else { continue }

            seenKeys.insert(key)
            hits.append((name, match.range.location))
        }

        return hits.sorted { $0.location < $1.location }.map(\.name)
    }
}
