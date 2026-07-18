import Foundation

/// Static mapping from podcast identity → fandom wiki provider config.
/// Add Critical Role / Dimension 20 entries here using the same shape.
struct ShowWikiMapping: Sendable {
    let id: String
    let itunesIDs: Set<String>
    let titleKeywords: [String]
    let wikiHost: String
    let attribution: String
    let synopsisSectionTitle: String
    /// Canonical player-character names (and common aliases) for role tagging.
    let knownPlayerCharacters: [String]
    let sourceID: String

    var apiBaseURL: URL {
        URL(string: "https://\(wikiHost)/api.php")!
    }

    var wikiBaseURL: URL {
        URL(string: "https://\(wikiHost)/wiki/")!
    }

    func pageURL(title: String) -> URL {
        let encoded = title.replacingOccurrences(of: " ", with: "_")
        return wikiBaseURL.appendingPathComponent(encoded)
    }
}

enum ShowWikiRegistry {
    static let all: [ShowWikiMapping] = [
        ShowWikiMapping(
            id: "naddpod",
            itunesIDs: ["1344003690"],
            titleKeywords: [
                "not another d&d podcast",
                "not another dnd podcast",
                "naddpod"
            ],
            wikiHost: "notanotherdndpodcast.fandom.com",
            attribution: "NADDPOD Wiki",
            synopsisSectionTitle: "Plot Synopsis",
            knownPlayerCharacters: [
                "Hardwon Surefoot", "Hardwon",
                "Moonshine Cybin", "Moonshine",
                "Beverly Toegold V", "Beverly Toegold", "Beverly", "Bev",
                "Calliope Petrichor", "Callie", "Calliope",
                "Calder Kildé", "Calder Kilde", "Calder",
                "Solum Bufo", "Sol", "Solum",
                "Pawpaw", "Balnor"
            ],
            sourceID: "naddpod-wiki"
        )
        // Follow-on providers (same ShowWikiMapping shape):
        // - Critical Role: itunesIDs for CR feeds, wikiHost criticalrole.fandom.com
        //   (or criticalrole.miraheze.org), synopsisSectionTitle "Synopsis"
        // - Dimension 20: dimension20.fandom.com, synopsis section varies by season
        // Match via itunesID first, then titleKeywords.
    ]

    static func mapping(for podcast: Podcast) -> ShowWikiMapping? {
        if let itunesID = podcast.itunesID,
           let match = all.first(where: { $0.itunesIDs.contains(itunesID) }) {
            return match
        }
        let normalized = normalize(podcast.title)
        return all.first { mapping in
            mapping.titleKeywords.contains { normalized.contains(normalize($0)) }
        }
    }

    static func isMapped(_ podcast: Podcast) -> Bool {
        mapping(for: podcast) != nil
    }

    private static func normalize(_ string: String) -> String {
        string
            .lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "'", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
