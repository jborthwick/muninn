import Foundation

// MARK: - Portable core: attach aftershows ("Short Rest: C3 Ep. 14") to the episode they follow,
// within a single feed.

struct AftershowLink {
    enum Method: String { case campaignAndNumber, subtitle, numberAndDate, wordsAndDate }
    let aftershowID: String
    let episodeID: String
    let label: String       // "Short Rest"
    let method: Method
}

enum EpisodeLinker {
    static func aftershows(in episodes: [GroupableEpisode], showTitle: String) -> [AftershowLink] {
        let shows = CampaignGrouper.normalizedShowNames(showTitle)
        let labels = aftershowLabels(in: episodes, showTitle: showTitle)
        guard !labels.isEmpty else { return [] }

        var after: [(GroupableEpisode, String, String, Key)] = []
        var mains: [(GroupableEpisode, Key)] = []
        for ep in episodes {
            if let (label, rest) = splitLabel(ep.title), labels.contains(label.lowercased()) {
                after.append((ep, label, rest, key(rest, shows: shows)))
            } else {
                mains.append((ep, key(ep.title, shows: shows)))
            }
        }

        var links: [AftershowLink] = []
        for (ep, label, rest, k) in after {
            // Aftershows come out after the episode; only look backwards (with a day of slack).
            let earlier = mains.filter { $0.0.pubDate <= ep.pubDate.addingTimeInterval(86400) }
            var hit: (GroupableEpisode, AftershowLink.Method)?
            if let c = k.campaign, let n = k.number,
               let m = closest(earlier.filter { $0.1.campaign == c && $0.1.number == n }.map(\.0), to: ep) {
                hit = (m, .campaignAndNumber)
            } else if let s = k.subtitle, s.count >= 6,
                      let m = closest(earlier.filter { $0.1.subtitle == s }.map(\.0), to: ep) {
                hit = (m, .subtitle)
            } else if let n = k.number,
                      let m = closest(earlier.filter { $0.1.number == n }.map(\.0), to: ep),
                      ep.pubDate.timeIntervalSince(m.pubDate) < 14 * 86400 {
                hit = (m, .numberAndDate)
            } else {
                // Specials without numbers: "Short Rest: Pathfinder Two-Shot (Part 1)" →
                // "Pathfinder Two-Shot: Menace Under Otari (Part 1)". All words present, within 14 days.
                let w = words(rest)
                if w.count >= 2,
                   let m = closest(earlier.filter { w.isSubset(of: words($0.0.title)) }.map(\.0), to: ep),
                   ep.pubDate.timeIntervalSince(m.pubDate) < 14 * 86400 {
                    hit = (m, .wordsAndDate)
                }
            }
            if let (m, method) = hit {
                links.append(.init(aftershowID: ep.id, episodeID: m.id, label: label, method: method))
            }
        }
        return links
    }

    /// A leading label whose remainders mention ≥2 different campaigns or mostly carry
    /// episode numbers ("Short Rest: Eldermourne …", "Short Rest: C3 …", "Short Rest: Ep. 15 …"),
    /// unlike a campaign prefix such as "Skaldova Season 2 - Ep. 7".
    static func aftershowLabels(in episodes: [GroupableEpisode], showTitle: String) -> Set<String> {
        let shows = CampaignGrouper.normalizedShowNames(showTitle)
        var rests: [String: [String]] = [:]
        for ep in episodes {
            if let (label, rest) = splitLabel(ep.title) { rests[label.lowercased(), default: []].append(rest) }
        }
        let campaigns = Set(CampaignGrouper.group(episodes, showTitle: showTitle)
            .filter { $0.source == .title }.map { normCampaign($0.name) })
        return Set(rests.compactMap { label, rs -> String? in
            guard rs.count >= 5 else { return nil }
            let mentioned = Set(rs.compactMap { CampaignGrouper.campaignName(fromTitle: $0, showNames: shows).map(normCampaign) })
                .intersection(campaigns).subtracting([normCampaign(label)])
            return mentioned.count >= 2 ? label : nil
        })
    }

    // MARK: Keys

    struct Key { var campaign: String?; var number: Int?; var subtitle: String? }

    static func key(_ title: String, shows: [String]) -> Key {
        let t = title.replacingOccurrences(of: #"\(w/[^)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        let number = firstInt(#"\bep(?:isode)?\.?\s*(\d+)"#, t)
        var subtitle: String?
        if let r = t.range(of: #"\bep(?:isode)?\.?\s*\d+\s*[:\-]\s*"#, options: [.regularExpression, .caseInsensitive]) {
            // Drop trailing "(The Moonstone Saga)" so main and aftershow subtitles compare equal.
            let s = String(t[r.upperBound...]).replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            subtitle = normTitle(s)
        }
        let campaign = CampaignGrouper.campaignName(fromTitle: t, showNames: shows).map(normCampaign)
        return Key(campaign: campaign, number: number, subtitle: subtitle?.isEmpty == false ? subtitle : nil)
    }

    /// "Short Rest: C3 Ep. 14" → ("Short Rest", "C3 Ep. 14"); "Short Rest - Skaldova Ep. 10" too.
    static func splitLabel(_ title: String) -> (String, String)? {
        guard let r = title.range(of: #"\s*(?::|\s-\s|\s–\s)\s*"#, options: .regularExpression) else { return nil }
        let label = title[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        let rest = title[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return label.isEmpty || rest.isEmpty ? nil : (label, rest)
    }

    static func words(_ s: String) -> Set<String> {
        let t = s.lowercased().replacingOccurrences(of: #"\(w/[^)]*\)"#, with: "", options: .regularExpression)
        return Set(t.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && $0 != "the" && $0 != "pt" && $0 != "part" })
    }

    static func normTitle(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"\(w/[^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }

    /// "Skaldova S2" == "Skaldova Season 2"; "The Mavrus Chronicles" == "Mavrus Chronicles".
    static func normCampaign(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"\bseason\s*(\d+)"#, with: "s$1", options: .regularExpression)
            .replacingOccurrences(of: #"^the\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }

    private static func closest(_ cands: [GroupableEpisode], to ep: GroupableEpisode) -> GroupableEpisode? {
        cands.min { abs($0.pubDate.timeIntervalSince(ep.pubDate)) < abs($1.pubDate.timeIntervalSince(ep.pubDate)) }
    }

    private static func firstInt(_ p: String, _ s: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }
}
