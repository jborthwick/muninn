import Foundation

// MARK: - Portable core (no app dependencies; could move into Muninn/Services as-is)

struct GroupableEpisode {
    let id: String
    let title: String
    let season: Int?
    let episodeType: String?   // itunes:episodeType: full / bonus / trailer
    let pubDate: Date
}

struct Campaign {
    enum Source: String { case title, season, extras, unsorted }
    var name: String
    var source: Source
    var episodeIDs: [String]        // oldest first
    var firstDate: Date
    var lastDate: Date
    /// Aftershows attached to episodes in this campaign (play each right after its episode).
    var aftershowIDs: [String] = []
    /// Story arcs inside the campaign, in order ("Legends of Irondeep", "The Frostwind Chapter").
    var arcs: [(name: String, count: Int)] = []
}

enum CampaignGrouper {
    /// Title-derived groups smaller than this are treated as noise.
    static let minTitleGroupSize = 3

    /// `aftershows`: aftershow episode ID → the episode it follows (from `EpisodeLinker`).
    static func group(_ episodes: [GroupableEpisode], showTitle: String,
                      aftershows: [String: String] = [:]) -> [Campaign] {
        let sorted = episodes.filter { aftershows[$0.id] == nil }.sorted { $0.pubDate < $1.pubDate }
        let showWords = normalizedShowNames(showTitle)

        // Pass 1: candidate name per episode from its title.
        var titleName: [String: String] = [:]
        for ep in sorted {
            if let name = campaignName(fromTitle: ep.title, showNames: showWords) {
                titleName[ep.id] = name
            }
        }
        // Drop title names that only match a couple of episodes (accidental pattern hits).
        let counts = Dictionary(grouping: titleName.values, by: { $0 }).mapValues(\.count)
        titleName = titleName.filter { counts[$0.value, default: 0] >= minTitleGroupSize }

        // Pass 1a: leftovers whose title mentions an established group name
        // ("Setup - The Adventure Zone: Abnimals", "… | The Glass Cannon Podcast Giantslayer").
        let established = Set(titleName.values).sorted { $0.count > $1.count }   // longest first
        for ep in sorted where titleName[ep.id] == nil {
            if let hit = established.first(where: { containsPhrase(ep.title, $0) }) { titleName[ep.id] = hit }
        }

        // Pass 1b: recurring prefixes among the rest ("D&D Court: …", "Cannon Fodder 12/11/24").
        // Merges into an existing title group when the prefix matches its name.
        var prefix: [String: String] = [:]
        for ep in sorted where titleName[ep.id] == nil {
            if let p = recurringPrefix(ep.title, showNames: showWords) { prefix[ep.id] = p }
        }
        let known = Dictionary(titleName.values.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let pCounts = Dictionary(grouping: prefix.values.map { $0.lowercased() }, by: { $0 }).mapValues(\.count)
        for (id, p) in prefix {
            if let existing = known[p.lowercased()] { titleName[id] = existing }
            else if pCounts[p.lowercased(), default: 0] >= minTitleGroupSize { titleName[id] = p }
        }

        // Pass 2: assign each episode a group key.
        var order: [String] = []
        var groups: [String: Campaign] = [:]
        func add(_ ep: GroupableEpisode, key: String, name: String, source: Campaign.Source) {
            if groups[key] == nil {
                order.append(key)
                groups[key] = Campaign(name: name, source: source, episodeIDs: [], firstDate: ep.pubDate, lastDate: ep.pubDate)
            }
            groups[key]!.episodeIDs.append(ep.id)
            groups[key]!.lastDate = ep.pubDate
        }

        for ep in sorted {
            let isExtra = ep.episodeType == "trailer" || ep.episodeType == "bonus"
            if let name = titleName[ep.id] {
                add(ep, key: "t:" + name.lowercased(), name: name, source: .title)
            } else if ep.title.range(of: #"^ep(?:isode)?\.?\s*\d+\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil {
                // Bare "Ep. 12: Title (Arc)" with no campaign name: the show's main numbered run.
                add(ep, key: "numbered", name: "Main Campaign", source: .title)
            } else if isExtra {
                add(ep, key: "extras", name: "Extras", source: .extras)
            } else if let s = ep.season {
                add(ep, key: "s:\(s)", name: "Season \(s)", source: .season)
            } else {
                add(ep, key: "unsorted", name: "Unsorted", source: .unsorted)
            }
        }

        // Pass 3: a season group whose sibling title-group covers the same season
        // gets that title's name ("Season 10" next to "Providence" → fold in).
        var result = order.compactMap { groups[$0] }
        result = foldSeasonsIntoNamedGroups(result, episodes: sorted)

        // Pass 4: attach aftershows to their episode's campaign; find arcs.
        let titles = Dictionary(sorted.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        var campaignOf: [String: Int] = [:]
        for (i, c) in result.enumerated() { for id in c.episodeIDs { campaignOf[id] = i } }
        for (after, episode) in aftershows { if let i = campaignOf[episode] { result[i].aftershowIDs.append(after) } }
        for i in result.indices { result[i].arcs = arcs(result[i].episodeIDs.compactMap { titles[$0] }) }
        return result
    }

    /// Consecutive runs of a recurring trailing parenthetical: "C3 Ep. 30: … (Legends of Irondeep)".
    static func arcs(_ titles: [String]) -> [(name: String, count: Int)] {
        let names = titles.map(arcName)
        let counts = Dictionary(grouping: names.compactMap { $0 }, by: { $0.lowercased() }).mapValues(\.count)
        var runs: [(name: String, count: Int)] = []
        for n in names {
            guard let n, counts[n.lowercased(), default: 0] >= 2 else { continue }
            if let last = runs.last, last.name.lowercased() == n.lowercased() { runs[runs.count - 1].count += 1 }
            else { runs.append((n, 1)) }
        }
        return runs
    }

    static func arcName(_ title: String) -> String? {
        guard let r = title.range(of: #"\(([^()]{4,40})\)\s*$"#, options: .regularExpression) else { return nil }
        let inner = String(title[r]).trimmingCharacters(in: CharacterSet(charactersIn: "() ").union(.whitespaces))
        if inner.range(of: #"^(?:w/|with |ft\.|feat|part|pt\.?|q&a|live|bonus)"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        return inner
    }

    // MARK: Title parsing

    private static let epMarker = #"(?:\b(?:ep(?:isode)?\.?\s*:?\s*#?\d+|e\d+|part\s+\d+|chapter\s+\w+)\b|#\d+(?:\.\d+)?)"#

    /// Returns a campaign/arc name implied by an episode title, or nil.
    static func campaignName(fromTitle raw: String, showNames: [String]) -> String? {
        let title = raw.replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. "Campaign 4, Episode 43" / "C3E67" / "C3 E121" / "C03 - Ep. 56"
        if let n = firstMatch(#"\bcampaign\s+(\d+)\b"#, in: title) ?? firstMatch(#"^c0*(\d+)\s*(?:-\s*)?e(?:p\.?)?\s*\d+"#, in: title) {
            return "Campaign \(n)"
        }

        // 2. Pipe-separated: pick the segment that carries the episode marker,
        //    or the first segment that isn't the show name / a system name.
        let pipes = title.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if pipes.count >= 2 {
            for seg in pipes where matches(epMarker + "|" + #"\bs\d+\s*e\d+\b"#, seg) {
                if let name = cleanName(strippingEpisodeMarkers(seg), showNames: showNames) { return name }
            }
            // "Fantasy High | Ep. 14 | Arcade Ambush": marker segment was bare, so take segment before it.
            //    "Scattered Pilgrims | Age of Umbra: Sallowlands | Episode 1 Part 1" → segment just before.
            if let idx = pipes.firstIndex(where: { isBareMarker($0) }), idx > 0 {
                let before = pipes[..<idx].last(where: { !isBareMarker($0) }) ?? pipes[0]
                if let name = cleanName(before, showNames: showNames) { return name }
            }
        }

        // 3. "Name 55: Episode title" (Friends at the Table) / "Name #40:" / "Name: Episode 6"
        //    / "Name Season 2 - Ep. 7" / "Axis Arc 4 Ep 6" / "Arc 14 Ep 8:"
        let prefixPatterns = [
            #"^(.+?\barc\s+\d+)\b"#,                                   // Axis Arc 4 / Arc 14
            #"^(.+?\bseason\s+\d+)\s*-?\s*ep"#,                         // Skaldova Season 2 - Ep. 7
            #"^(.+?)\s*[:\-]\s*(?:episode|ep\.?)\s*\d+"#,               // World Turner: Episode 6 / Name - Ep. 3
            #"^(.+?)\s+(?:episode|ep\.?)\s*\d+"#,                       // Name Episode 12
            #"^(.+?)\s+#\d+(?:\.\d+)?\b"#,                              // WWW #40 / DF2 #3.19
            #"^([^:]+?)\s+\d{1,3}\s*:"#,                                // Perpetua 55: / PARTIZAN 14:
        ]
        for p in prefixPatterns {
            if let cand = firstMatch(p, in: title), let name = cleanName(cand, showNames: showNames) {
                return name
            }
        }
        return nil
    }

    /// Leading label before the first separator, with dates/numbers/markers removed.
    static func recurringPrefix(_ title: String, showNames: [String]) -> String? {
        var t = title.replacingOccurrences(of: #"\b\d{1,2}/\d{1,2}/\d{2,4}\b"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?,?\s*(?:\d{4})?"#, with: "", options: [.regularExpression, .caseInsensitive])
        let head = t.components(separatedBy: CharacterSet(charactersIn: ":|(–")).first ?? t
        let head2 = head.components(separatedBy: " - ").first ?? head
        var name = strippingEpisodeMarkers(head2)
        name = name.replacingOccurrences(of: #"[\s#]*\d+\s*$"#, with: "", options: .regularExpression)
        return cleanName(name, showNames: showNames)
    }

    private static func isBareMarker(_ seg: String) -> Bool {
        strippingEpisodeMarkers(seg).trimmingCharacters(in: CharacterSet(charactersIn: " :-|,.")).isEmpty
    }

    /// Whole-phrase, case-sensitive containment (campaign names are capitalised; avoids "dust" in prose).
    private static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        let p = #"(?<![\w])"# + NSRegularExpression.escapedPattern(for: phrase) + #"(?![\w])"#
        return text.range(of: p, options: .regularExpression) != nil
    }

    private static func strippingEpisodeMarkers(_ s: String) -> String {
        var out = s
        for p in [#"\bs\d+\s*e\d+\b"#, epMarker, #"\bseason\s+\d+\b"#, #"\bpt\.?\s*\d+\b"#] {
            out = out.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    /// Strip show name, marker leftovers, punctuation; reject names that are empty or generic.
    private static func cleanName(_ raw: String, showNames: [String]) -> String? {
        var s = raw
        for show in showNames where !show.isEmpty {
            s = s.replacingOccurrences(of: show, with: "", options: [.caseInsensitive])
        }
        s = s.replacingOccurrences(of: #"^[\s:\-–|.,#]+|[\s:\-–|.,#]+$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        let lower = s.lowercased()
        let generic: Set<String> = ["", "the", "ep", "episode", "bonus", "trailer", "part", "season", "s", "the podcast", "podcast", "presents"]
        if generic.contains(lower) { return nil }
        if lower.range(of: #"^(?:s|season|ep|episode|e)?\s*\d+$"#, options: .regularExpression) != nil { return nil }
        if s.count > 40 { return nil }   // probably an episode title, not a campaign name
        return s
    }

    static func normalizedShowNames(_ title: String) -> [String] {
        var names = [title]
        // "The Glass Cannon Podcast" → also strip "Glass Cannon Podcast", "The Glass Cannon"
        let noThe = title.replacingOccurrences(of: #"^the\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        names.append(noThe)
        let noPod = title.replacingOccurrences(of: #"\s+podcast$"#, with: "", options: [.regularExpression, .caseInsensitive])
        names.append(noPod)
        names.append(noPod.replacingOccurrences(of: #"^the\s+"#, with: "", options: [.regularExpression, .caseInsensitive]))
        return Array(Set(names)).sorted { $0.count > $1.count }   // longest first
    }

    private static func foldSeasonsIntoNamedGroups(_ groups: [Campaign], episodes: [GroupableEpisode]) -> [Campaign] {
        let seasonOf = Dictionary(uniqueKeysWithValues: episodes.map { ($0.id, $0.season) })
        var out = groups
        for i in out.indices where out[i].source == .season {
            let season = seasonOf[out[i].episodeIDs[0]] ?? nil
            // Named groups whose episodes are all in this season.
            let named = out.indices.filter { j in
                out[j].source == .title && out[j].episodeIDs.allSatisfy { seasonOf[$0] == season }
            }
            if named.count == 1, out[named[0]].episodeIDs.count >= out[i].episodeIDs.count {
                let j = named[0]
                out[j].episodeIDs += out[i].episodeIDs
                out[j].firstDate = min(out[j].firstDate, out[i].firstDate)
                out[j].lastDate = max(out[j].lastDate, out[i].lastDate)
                out[i].episodeIDs = []
            }
        }
        return out.filter { !$0.episodeIDs.isEmpty }
    }

    // MARK: Regex helpers

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func matches(_ pattern: String, _ s: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
