import Foundation

/// Parses artist credits from character infobox captions / “Art by …” text.
enum ArtworkCreditParsing {
    struct ArtworkCredit: Sendable, Equatable {
        let name: String
        /// External portfolio/social link when the wiki caption includes one.
        let url: String?
        /// Wiki page title for credits like `[[Caldwell Tanner]]`.
        let wikiTitle: String?
    }

    static func artworkCredit(from wikitext: String) -> ArtworkCredit? {
        let fields = CharacterFactParsing.characterInfoboxFields(from: wikitext)
        let captionCandidates = [
            fields["caption-image1"],
            fields["caption1"],
            fields["caption"]
        ].compactMap { $0 }

        for caption in captionCandidates {
            if let credit = parseArtworkCredit(from: caption) {
                return credit
            }
        }

        let lede = WikiTextParsing.lede(from: wikitext)
        if let match = WikiTextParsing.firstMatch(
            #"(?is)((?:character art by|image by|art by|artwork by).{0,240})"#,
            in: lede
        ), match.numberOfRanges >= 2 {
            let snippet = WikiTextParsing.substring(match, 1, in: lede)
            return parseArtworkCredit(from: snippet)
        }
        return nil
    }

    private static func parseArtworkCredit(from raw: String) -> ArtworkCredit? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // External: [https://example.com Artist Name]
        if let match = WikiTextParsing.firstMatch(
            #"\[(https?://[^\s\]]+)\s+([^\]]+)\]"#,
            in: trimmed
        ), match.numberOfRanges >= 3 {
            let url = WikiTextParsing.substring(match, 1, in: trimmed)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = cleanArtistName(WikiTextParsing.substring(match, 2, in: trimmed))
            if let name, url.nilIfBlank != nil {
                return ArtworkCredit(name: name, url: url, wikiTitle: nil)
            }
        }

        // Wiki link: [[Caldwell Tanner]] or [[Caldwell Tanner|Caldy]]
        if let match = WikiTextParsing.firstMatch(
            #"\[\[([^\]|#]+)(?:\|([^\]]+))?\]\]"#,
            in: trimmed
        ), match.numberOfRanges >= 2 {
            let page = WikiTextParsing.substring(match, 1, in: trimmed)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let label = match.numberOfRanges >= 3
                ? WikiTextParsing.substring(match, 2, in: trimmed)
                : ""
            var name = (label.nilIfBlank ?? page)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let handleMatch = WikiTextParsing.firstMatch(#"/@([A-Za-z0-9_]+)"#, in: trimmed),
               handleMatch.numberOfRanges >= 2 {
                let handle = WikiTextParsing.substring(handleMatch, 1, in: trimmed)
                if !name.localizedCaseInsensitiveContains("@\(handle)") {
                    name = "\(name)/@\(handle)"
                }
            }
            if let cleaned = cleanArtistName(name) {
                return ArtworkCredit(name: cleaned, url: nil, wikiTitle: page.nilIfBlank)
            }
        }

        // Plain-text fallback after “Art by …”
        if let match = WikiTextParsing.firstMatch(
            #"(?i)(?:character art by|image by|art by|artwork by)\s*(.+)$"#,
            in: trimmed
        ), match.numberOfRanges >= 2 {
            let tail = WikiTextParsing.substring(match, 1, in: trimmed)
            if let cleaned = cleanArtistName(WikiTextParsing.wikitextToPlain(tail)) {
                return ArtworkCredit(name: cleaned, url: nil, wikiTitle: nil)
            }
        }

        return nil
    }

    private static func cleanArtistName(_ raw: String) -> String? {
        var name = raw
        name = name.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\{\{[^}]+\}\}"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"^\(+|\)+$"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;")))
        name = name.replacingOccurrences(
            of: #"^(?i)(?:character art by|image by|art by|artwork by)\s+"#,
            with: "",
            options: .regularExpression
        )
        guard name.count >= 2, name.count <= 80 else { return nil }
        return name.nilIfBlank
    }
}
