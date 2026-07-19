import Foundation

/// One PC identity: fetch `wikiTitle`, match any alias (including diacritic variants).
struct PlayerCharacterIdentity: Sendable, Equatable {
    /// Exact MediaWiki page title.
    let wikiTitle: String
    /// Alternate names that should collapse onto `wikiTitle`.
    let aliases: [String]

    var allNames: [String] { [wikiTitle] + aliases }
}

/// Static mapping from podcast identity → fandom wiki provider config.
/// Add Critical Role / Dimension 20 entries here using the same shape.
struct ShowWikiMapping: Sendable {
    let id: String
    let itunesIDs: Set<String>
    let titleKeywords: [String]
    let wikiHost: String
    let attribution: String
    let synopsisSectionTitle: String
    let playerCharacters: [PlayerCharacterIdentity]
    let sourceID: String

    /// Flat alias list for mention detection / sorting.
    var knownPlayerCharacters: [String] {
        playerCharacters.flatMap(\.allNames)
    }

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

    /// Stable wiki redirect to a file (fallback when imageinfo is unavailable).
    func specialFilePathURL(fileName: String, width: Int = 400) -> URL? {
        var name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix("file:") {
            name = String(name.dropFirst(5))
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        name = name.replacingOccurrences(of: " ", with: "_")
        let base = URL(string: "https://\(wikiHost)/wiki/Special:FilePath/")!
        var components = URLComponents(url: base.appendingPathComponent(name), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "width", value: "\(width)")]
        return components.url
    }

    /// Collapse aliases like "Callie" / "Calder Kilde" onto the wiki page title.
    func canonicalCharacterName(for name: String) -> String? {
        let foldedName = Self.fold(name)

        for pc in playerCharacters {
            for alias in pc.allNames where foldedName == Self.fold(alias) {
                return pc.wikiTitle
            }
        }

        // Partial match against the canonical title only ("Beverly Toegold" → "… V").
        // Skip very short stems so "Sol" does not swallow unrelated "Soldier" NPCs —
        // short aliases are handled by exact match above.
        for pc in playerCharacters {
            let foldedTitle = Self.fold(pc.wikiTitle)
            let shorter = min(foldedName.count, foldedTitle.count)
            guard shorter >= 4 else { continue }
            if foldedName.hasPrefix(foldedTitle) || foldedTitle.hasPrefix(foldedName) {
                return pc.wikiTitle
            }
        }
        return nil
    }

    func isKnownPlayerCharacter(_ name: String) -> Bool {
        canonicalCharacterName(for: name) != nil
    }

    /// Case- and diacritic-insensitive fold for alias matching.
    static func fold(_ string: String) -> String {
        string
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
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
            playerCharacters: [
                .init(wikiTitle: "Hardwon Surefoot", aliases: ["Hardwon"]),
                .init(wikiTitle: "Moonshine Cybin", aliases: ["Moonshine"]),
                .init(wikiTitle: "Beverly Toegold V", aliases: ["Beverly Toegold", "Beverly", "Bev"]),
                .init(wikiTitle: "Calliope Petrichor", aliases: ["Calliope", "Callie"]),
                .init(wikiTitle: "Calder Kildé", aliases: ["Calder Kilde", "Calder"]),
                .init(wikiTitle: "Solum Bufo", aliases: ["Solum", "Sol"]),
                .init(wikiTitle: "Pawpaw", aliases: []),
                .init(wikiTitle: "Balnor", aliases: [])
            ],
            sourceID: "naddpod-wiki"
        ),
        // Smaller show first: rotating cast, Amalar/Axis arcs on Fandom.
        // RSS titles look like "Arc 1 Ep.1: … PART 1" / "Axis Arc 2 Ep 6: …";
        // wiki pages are usually "Arc N Episode M: …" — search fallback helps;
        // Arc-aware exact matchers may still be needed for reliability.
        ShowWikiMapping(
            id: "rotating-heroes",
            itunesIDs: ["1709543811"],
            titleKeywords: [
                "rotating heroes",
                "rotating heroes podcast"
            ],
            wikiHost: "rotatingheroespodcast.fandom.com",
            attribution: "Rotating Heroes Wiki",
            // Most episode pages put the plot under Description; older ones
            // may also have an empty Synopsis heading.
            synopsisSectionTitle: "Description",
            playerCharacters: [
                .init(wikiTitle: "Adonis Napoleon Daedalus Sprocket", aliases: ["Adonis"]),
                .init(wikiTitle: "Astrid Starborn", aliases: ["Astrid"]),
                .init(wikiTitle: "Auliver Flash", aliases: ["Auliver"]),
                .init(wikiTitle: "Brenda Elizabeth", aliases: ["Brenda"]),
                .init(wikiTitle: "Chumsley Freakums", aliases: ["Chumsley"]),
                .init(wikiTitle: "Dooter", aliases: []),
                .init(wikiTitle: "Ember Elysiana", aliases: ["Ember"]),
                .init(wikiTitle: "Fhinne Foode", aliases: ["Fhinne"]),
                .init(wikiTitle: "Fraeya Black", aliases: ["Fraeya", "Freaya"]),
                .init(wikiTitle: "Grey", aliases: []),
                .init(wikiTitle: "Grib", aliases: []),
                .init(wikiTitle: "Harland", aliases: []),
                .init(wikiTitle: "Jin", aliases: []),
                .init(wikiTitle: "John Daffodil", aliases: []),
                .init(wikiTitle: "Kerp", aliases: []),
                .init(wikiTitle: "Morgana Chambers", aliases: ["Morgana"]),
                .init(wikiTitle: "Nancy Rae Gan", aliases: ["Nancy"]),
                .init(wikiTitle: "Rufus Cutler", aliases: ["Rufus"]),
                .init(wikiTitle: "Sago Glegg", aliases: ["Sago"]),
                .init(wikiTitle: "Shadrick Turlett", aliases: ["Shadrick", "Shaddy"]),
                .init(wikiTitle: "Sir Vissel Divanostra", aliases: ["Vissel", "Sir Vissel"]),
                .init(wikiTitle: "Soapfeathers", aliases: []),
                .init(wikiTitle: "Squeej", aliases: []),
                .init(wikiTitle: "Strundleteet", aliases: []),
                .init(wikiTitle: "Teeths", aliases: []),
                .init(wikiTitle: "Tionne Riche", aliases: ["Tionne"]),
                .init(wikiTitle: "Tuesday Freakums", aliases: ["Tuesday"]),
                .init(wikiTitle: "Tuffy", aliases: []),
                .init(wikiTitle: "Tundra", aliases: []),
                .init(wikiTitle: "Turbine Spizzlesink", aliases: ["Turbine"]),
                .init(wikiTitle: "Tyson Fallensong", aliases: ["Tyson"]),
                .init(wikiTitle: "Uh Oh", aliases: []),
                .init(wikiTitle: "Vana Victar", aliases: ["Vana"]),
                .init(wikiTitle: "Yernal P. Turlett", aliases: ["Yernal"]),
                .init(wikiTitle: "Zazalli Daggrin", aliases: ["Zazalli"])
            ],
            sourceID: "rotating-heroes-wiki"
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
