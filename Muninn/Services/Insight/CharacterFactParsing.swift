import Foundation

/// Spoiler-safe X-ray facts from character infoboxes / ledes.
enum CharacterFactParsing {
    /// Class, Species, Player, Pronouns — no status/death/alias spoilers.
    static func characterFacts(from wikitext: String) -> [InsightCharacterFact] {
        let fields = characterInfoboxFields(from: wikitext)
        var facts: [InsightCharacterFact] = []

        if let value = spoilerSafeClass(fields["class"]) {
            facts.append(InsightCharacterFact(label: "Class", value: value))
        }
        if let value = spoilerSafeSpecies(fields["species"]) {
            facts.append(InsightCharacterFact(label: "Species", value: value))
        }
        if let player = playedBy(from: wikitext) {
            facts.append(InsightCharacterFact(label: "Player", value: player))
        }
        if let pronouns = singleLinePlain(fields["pronouns"]),
           pronouns.lowercased() != "none",
           pronouns.lowercased() != "n/a" {
            facts.append(InsightCharacterFact(label: "Pronouns", value: pronouns))
        }
        return facts
    }

    /// Infobox `image1` / `image` filename for artwork fallback.
    static func infoboxImageFileName(from wikitext: String) -> String? {
        let fields = characterInfoboxFields(from: wikitext)
        let raw = fields["image1"] ?? fields["image"]
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        // Take first line / pipe segment only.
        if let br = value.range(of: "<br", options: .caseInsensitive) {
            value = String(value[..<br.lowerBound])
        }
        if let pipe = value.firstIndex(of: "|") {
            value = String(value[..<pipe])
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("file:") {
            value = String(value.dropFirst(5))
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 3, value.contains(".") else { return nil }
        return value
    }

    /// Parse `{{Infobox character|...}}` / `{{Infobox_character|...}}` key/value fields.
    static func characterInfoboxFields(from wikitext: String) -> [String: String] {
        guard let body = extractTemplateBody(
            named: ["Infobox character", "Infobox_character"],
            from: wikitext
        ) else { return [:] }

        var fields: [String: String] = [:]
        for param in splitTemplateParams(body) {
            guard let eq = param.firstIndex(of: "=") else { continue }
            let key = param[..<eq]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = param[param.index(after: eq)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            fields[key] = value
        }
        return fields
    }

    /// "…played by [[Jake Hurwitz]]" from the character lede.
    static func playedBy(from wikitext: String) -> String? {
        let source = WikiTextParsing.lede(from: wikitext)
        let patterns = [
            #"(?i)played by\s*\[\[([^\]|#]+)(?:\|[^\]]+)?\]\]"#,
            #"(?i)played by\s+([A-Z][A-Za-z.'\-]+(?:\s+[A-Z][A-Za-z.'\-]+)+)"#
        ]
        for pattern in patterns {
            guard let match = WikiTextParsing.firstMatch(pattern, in: source),
                  match.numberOfRanges >= 2 else { continue }
            let name = WikiTextParsing.substring(match, 1, in: source)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let plain = name.nilIfBlank, plain.count >= 3, plain.count <= 60 {
                return plain
            }
        }
        return nil
    }

    // MARK: - Infobox helpers

    /// Body inside `{{Name|…}}` (outer braces stripped), or nil if not found.
    static func extractTemplateBody(named names: [String], from text: String) -> String? {
        let lower = text.lowercased()
        for name in names {
            let needle = "{{" + name.lowercased()
            guard let start = lower.range(of: needle) else { continue }
            let from = start.lowerBound
            var i = text.index(from, offsetBy: 2)
            var depth = 1
            while i < text.endIndex {
                if text[i] == "{", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "{" {
                    depth += 1
                    i = text.index(i, offsetBy: 2)
                    continue
                }
                if text[i] == "}", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "}" {
                    depth -= 1
                    if depth == 0 {
                        let inner = text[text.index(from, offsetBy: 2)..<i]
                        if let pipe = inner.firstIndex(of: "|") {
                            return String(inner[inner.index(after: pipe)...])
                        }
                        return ""
                    }
                    i = text.index(i, offsetBy: 2)
                    continue
                }
                i = text.index(after: i)
            }
        }
        return nil
    }

    /// Split template params on top-level `|` (respects `[[…]]` / `{{…}}`).
    static func splitTemplateParams(_ body: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var linkDepth = 0
        var templateDepth = 0
        var i = body.startIndex

        while i < body.endIndex {
            let ch = body[i]
            let next = body.index(after: i)
            if ch == "[", next < body.endIndex, body[next] == "[" {
                linkDepth += 1
                current.append("[[")
                i = body.index(i, offsetBy: 2)
                continue
            }
            if ch == "]", next < body.endIndex, body[next] == "]" {
                linkDepth = max(0, linkDepth - 1)
                current.append("]]")
                i = body.index(i, offsetBy: 2)
                continue
            }
            if ch == "{", next < body.endIndex, body[next] == "{" {
                templateDepth += 1
                current.append("{{")
                i = body.index(i, offsetBy: 2)
                continue
            }
            if ch == "}", next < body.endIndex, body[next] == "}" {
                templateDepth = max(0, templateDepth - 1)
                current.append("}}")
                i = body.index(i, offsetBy: 2)
                continue
            }
            if ch == "|", linkDepth == 0, templateDepth == 0 {
                parts.append(current)
                current = ""
                i = next
                continue
            }
            current.append(ch)
            i = next
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Class without level / former oath / multi-class `<br>` tails.
    static func spoilerSafeClass(_ raw: String?) -> String? {
        guard var value = firstInfoboxLine(raw) else { return nil }
        value = value.replacingOccurrences(
            of: #"\s*\(Formerly[^)]*\)"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\s*\(Campaign\s+\d+\)"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\s+\(Level\s+\d+\)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        value = value.replacingOccurrences(
            of: #"\s+\d+\s*$"#,
            with: "",
            options: .regularExpression
        )
        return value.nilIfBlank
    }

    /// Species without "(Previously…)" / form-shift tails.
    static func spoilerSafeSpecies(_ raw: String?) -> String? {
        guard var value = firstInfoboxLine(raw) else { return nil }
        value = value.replacingOccurrences(
            of: #"\s*\(Previously[^)]*\)"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return value.nilIfBlank
    }

    private static func firstInfoboxLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let first = raw
            .components(separatedBy: "<br")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
        return singleLinePlain(first)
    }

    private static func singleLinePlain(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let plain = WikiTextParsing.wikitextToPlain(raw)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard plain.count >= 2, plain.count <= 80 else { return nil }
        return plain.nilIfBlank
    }
}
