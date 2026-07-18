import Foundation

/// Wikitext section/link helpers for MediaWiki episode and character pages.
enum WikiTextParsing {
    static func extractSection(from wikitext: String, named section: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: section)
        // Heading must be on its own line. Do not let whitespace skip past the next
        // heading — empty sections used to capture "== Trivia ==" as the body.
        let pattern = #"(?ims)^==+\s*\#(escaped)\s*==+\s*$(.*?)(?=^==+|\z)"#
            .replacingOccurrences(of: "#(escaped)", with: escaped)
        guard let match = firstMatch(pattern, in: wikitext),
              match.numberOfRanges >= 2 else { return nil }
        let body = substring(match, 1, in: wikitext)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !body.hasPrefix("==") else { return nil }
        return body
    }

    /// Narrative paragraphs from the episode lede when Plot Synopsis is empty on-wiki.
    static func episodeLedeSynopsis(from wikitext: String) -> String? {
        let rawLede = lede(from: wikitext)
        var paragraphs: [String] = []
        for block in rawLede.components(separatedBy: "\n\n") {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("{{") || trimmed.hasPrefix("[[File") { continue }
            let plain = wikitextToPlain(trimmed)
            guard plain.count >= 40 else { continue }
            // Skip the stock "X is the Nth episode of Campaign…" blurb.
            if plain.range(
                of: #"\bis the\b.+\bepisode\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                continue
            }
            paragraphs.append(plain)
        }
        guard !paragraphs.isEmpty else { return nil }
        return paragraphs.joined(separator: "\n\n").nilIfBlank
    }

    static func lede(from wikitext: String) -> String {
        if let range = wikitext.range(of: "\n==") {
            return String(wikitext[..<range.lowerBound])
        }
        return wikitext
    }

    static func characterNames(
        fromLede lede: String,
        synopsis: String,
        knownPCs: [String]
    ) -> [String] {
        var names: [String] = []
        var seen = Set<String>()

        let skipPrefixes = [":", "File:", "Category:", "Image:"]
        let skipExact: Set<String> = [
            "Duck Team", "Mothership", "Bahumia", "Eldermourne", "Trinyvale",
            "Irondeep", "Irondeep Mountains", "Moonstone Swamp", "Crick"
        ]

        func consider(_ raw: String) {
            var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pipe = name.split(separator: "|").last {
                name = String(pipe).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard name.count >= 2, name.count <= 60 else { return }
            if skipPrefixes.contains(where: { name.hasPrefix($0) }) { return }
            if skipExact.contains(name) { return }
            if name.lowercased().contains("episode") { return }
            if name.lowercased().hasPrefix("campaign ") { return }
            if name.lowercased().hasSuffix(" mountains")
                || name.lowercased().hasSuffix(" kingdom")
                || name.lowercased().hasSuffix(" forest")
                || name.lowercased().hasSuffix(" swamp") {
                return
            }
            let key = name.lowercased()
            guard seen.insert(key).inserted else { return }
            names.append(name)
        }

        let linkPattern = #"\[\[([^\]|#]+)(?:\|[^\]]+)?\]\]"#
        let combined = lede + "\n" + synopsis
        if let regex = try? NSRegularExpression(pattern: linkPattern) {
            let range = NSRange(combined.startIndex..., in: combined)
            regex.enumerateMatches(in: combined, range: range) { match, _, _ in
                guard let match, match.numberOfRanges >= 2 else { return }
                consider(substring(match, 1, in: combined))
            }
        }

        let lowerCombined = combined.lowercased()
        for pc in knownPCs where pc.count > 2 {
            if lowerCombined.contains(pc.lowercased()) {
                consider(pc)
            }
        }

        let knownLower = Set(knownPCs.map { $0.lowercased() })
        return names.sorted { a, b in
            let aPC = knownLower.contains(a.lowercased())
                || knownPCs.contains(where: { a.lowercased().hasPrefix($0.lowercased()) })
            let bPC = knownLower.contains(b.lowercased())
                || knownPCs.contains(where: { b.lowercased().hasPrefix($0.lowercased()) })
            if aPC != bPC { return aPC && !bPC }
            return a < b
        }
    }

    static func characterIntroText(from wikitext: String) -> String? {
        if let bio = extractSection(from: wikitext, named: "Bio") {
            return String(wikitextToPlain(bio).prefix(600)).nilIfBlank
        }
        let ledeText = lede(from: wikitext)
        let paragraphs = ledeText
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("{{") && !$0.hasPrefix("[[File") }
        guard let first = paragraphs.first else { return nil }
        return String(wikitextToPlain(first).prefix(600)).nilIfBlank
    }

    static func wikitextToPlain(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"\[\[([^\]|]+)\|([^\]]+)\]\]"#,
            with: "$2",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\[\[([^\]]+)\]\]"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\{\{[^}]+\}\}"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "'''", with: "")
        result = result.replacingOccurrences(of: "''", with: "")
        result = result.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range)
    }

    static func substring(_ match: NSTextCheckingResult, _ idx: Int, in text: String) -> String {
        guard let range = Range(match.range(at: idx), in: text) else { return "" }
        return String(text[range])
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
