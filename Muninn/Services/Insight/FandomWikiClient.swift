import Foundation

/// MediaWiki Action API client for Fandom (and compatible) wikis. No HTML scraping.
actor FandomWikiClient {
    static let shared = FandomWikiClient()

    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    struct ResolvedEpisodePage: Sendable {
        let title: String
        let pageURL: URL
        let synopsis: String?
        let characterNames: [String]
    }

    struct CharacterIntro: Sendable {
        let name: String
        let intro: String
        let pageURL: URL
    }

    func resolveEpisode(
        mapping: ShowWikiMapping,
        episodeTitle: String
    ) async throws -> ResolvedEpisodePage? {
        guard let pageTitle = try await resolvePageTitle(
            mapping: mapping,
            episodeTitle: episodeTitle
        ) else {
            return nil
        }

        let parsed = try await parsePage(mapping: mapping, title: pageTitle)
        let synopsis = WikiTextParsing.extractSection(
            from: parsed.wikitext,
            named: mapping.synopsisSectionTitle
        ).map(WikiTextParsing.wikitextToPlain)

        let lede = WikiTextParsing.lede(from: parsed.wikitext)
        let names = WikiTextParsing.characterNames(
            fromLede: lede,
            synopsis: synopsis ?? "",
            knownPCs: mapping.knownPlayerCharacters
        )

        return ResolvedEpisodePage(
            title: pageTitle,
            pageURL: mapping.pageURL(title: pageTitle),
            synopsis: synopsis?.nilIfBlank,
            characterNames: names
        )
    }

    func fetchCharacterIntro(
        mapping: ShowWikiMapping,
        name: String
    ) async throws -> CharacterIntro? {
        let parsed = try await parsePage(mapping: mapping, title: name)
        guard parsed.exists else { return nil }
        let intro = WikiTextParsing.characterIntroText(from: parsed.wikitext)
        guard let intro, !intro.isEmpty else { return nil }
        return CharacterIntro(
            name: parsed.title,
            intro: intro,
            pageURL: mapping.pageURL(title: parsed.title)
        )
    }

    // MARK: - Private

    private struct SearchHit {
        let title: String
    }

    private struct ParsedPage {
        let title: String
        let wikitext: String
        let exists: Bool
    }

    /// Pick the wiki page whose title best matches the RSS episode title.
    private func resolvePageTitle(
        mapping: ShowWikiMapping,
        episodeTitle: String
    ) async throws -> String? {
        // Exact titles first: some early campaign pages (e.g. Moonstone Ep. 1)
        // never appear in MediaWiki search, which then ranks lore pages instead.
        for candidate in Self.exactTitleCandidates(from: episodeTitle) {
            if let resolved = try await existingPageTitle(mapping: mapping, title: candidate) {
                let score = Self.similarityScore(
                    episodeTitle: episodeTitle,
                    pageTitle: resolved
                )
                if score >= 0.45 || Self.episodeNumbersMatch(episodeTitle, resolved) {
                    return resolved
                }
            }
        }

        var bestTitle: String?
        var bestScore = 0.0

        for query in Self.searchQueries(from: episodeTitle) {
            let results = try await searchResults(mapping: mapping, query: query)
            for hit in results {
                let score = Self.similarityScore(
                    episodeTitle: episodeTitle,
                    pageTitle: hit.title
                )
                if score > bestScore {
                    bestScore = score
                    bestTitle = hit.title
                }
            }
            if bestScore >= 0.72 { break }
        }

        // Bare "Episode 1" must not beat a clearly different campaign.
        return bestScore >= 0.35 ? bestTitle : nil
    }

    private func existingPageTitle(
        mapping: ShowWikiMapping,
        title: String
    ) async throws -> String? {
        var components = URLComponents(url: mapping.apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "titles", value: title),
            .init(name: "redirects", value: "1"),
            .init(name: "format", value: "json")
        ]
        guard let url = components.url else { return nil }
        let (data, _) = try await session.data(from: url)
        let response = try decoder.decode(TitlesResponse.self, from: data)
        guard let pages = response.query?.pages else { return nil }
        for page in pages.values where page.missing == nil && page.pageid != nil {
            return page.title
        }
        return nil
    }

    private func searchResults(
        mapping: ShowWikiMapping,
        query: String
    ) async throws -> [SearchHit] {
        var components = URLComponents(url: mapping.apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "list", value: "search"),
            .init(name: "srsearch", value: query),
            .init(name: "srlimit", value: "10"),
            .init(name: "format", value: "json")
        ]
        guard let url = components.url else { return [] }
        let (data, _) = try await session.data(from: url)
        let response = try decoder.decode(SearchResponse.self, from: data)
        return (response.query?.search ?? []).map { SearchHit(title: $0.title) }
    }

    private func parsePage(mapping: ShowWikiMapping, title: String) async throws -> ParsedPage {
        var components = URLComponents(url: mapping.apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "action", value: "parse"),
            .init(name: "page", value: title),
            .init(name: "prop", value: "wikitext"),
            .init(name: "redirects", value: "1"),
            .init(name: "format", value: "json")
        ]
        guard let url = components.url else {
            return ParsedPage(title: title, wikitext: "", exists: false)
        }
        let (data, _) = try await session.data(from: url)
        if let error = try? decoder.decode(ParseErrorEnvelope.self, from: data),
           error.error != nil {
            return ParsedPage(title: title, wikitext: "", exists: false)
        }
        let response = try decoder.decode(ParseResponse.self, from: data)
        guard let parse = response.parse else {
            return ParsedPage(title: title, wikitext: "", exists: false)
        }
        return ParsedPage(
            title: parse.title,
            wikitext: parse.wikitext?.value ?? "",
            exists: true
        )
    }

    // MARK: - Matching

    /// Construct likely wiki titles from RSS forms like "Ep. 1 Green Teens Gone (The Moonstone Saga)".
    nonisolated static func exactTitleCandidates(from episodeTitle: String) -> [String] {
        var titles: [String] = []
        let title = episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = parseEpStyleTitle(title) {
            let body = parsed.body
            if let saga = parsed.saga {
                titles.append("Episode \(parsed.number): \(body) (\(saga))")
            }
            titles.append("Episode \(parsed.number): \(body)")
        }

        if let named = namedCampaignEpisodeQuery(title),
           let subtitle = episodeSubtitle(title) {
            titles.append("\(named): \(subtitle)")
        }

        titles.append(title)

        var seen = Set<String>()
        return titles.filter { seen.insert($0.lowercased()).inserted }
    }

    nonisolated static func searchQueries(from episodeTitle: String) -> [String] {
        var queries: [String] = []
        let title = episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = parseEpStyleTitle(title) {
            queries.append("Episode \(parsed.number): \(parsed.body)")
            queries.append(parsed.body)
            if let saga = parsed.saga {
                queries.append("\(parsed.body) (\(saga))")
            }
        }

        if let named = namedCampaignEpisodeQuery(title) {
            queries.append(named)
        }
        if let campaign = matchCampaignEpisode(title) {
            queries.append("Campaign \(campaign.campaign), Episode \(campaign.episode)")
        }
        if let subtitle = episodeSubtitle(title), subtitle.count >= 4 {
            queries.append(subtitle)
            if let named = namedCampaignPrefix(title) {
                queries.append("\(named) \(subtitle)")
            }
        }
        if let ep = matchBareEpisode(title) {
            queries.append("Episode \(ep):")
        }
        queries.append(title)

        var seen = Set<String>()
        return queries.filter { seen.insert($0.lowercased()).inserted }
    }

    nonisolated static func similarityScore(episodeTitle: String, pageTitle: String) -> Double {
        let episodeTokens = significantTokens(episodeTitle)
        let pageTokens = significantTokens(pageTitle)
        guard !episodeTokens.isEmpty, !pageTokens.isEmpty else { return 0 }

        let overlap = episodeTokens.intersection(pageTokens).count
        let union = episodeTokens.union(pageTokens).count
        var score = Double(overlap) / Double(union)

        let rssEp = episodeNumberInTitle(episodeTitle)
        let pageEp = episodeNumberInTitle(pageTitle)

        if let rssEp, let pageEp, rssEp == pageEp {
            score += 0.35
        }
        if rssEp != nil, looksLikeEpisodePage(pageTitle) {
            score += 0.2
        }
        // Lore pages ("The Green Teens") often outrank missing Ep. 1 search hits.
        if rssEp != nil, !looksLikeEpisodePage(pageTitle) {
            score -= 0.45
        }
        if looksLikeEpisodePage(pageTitle) {
            score += 0.05
        }
        if let rssCampaign = namedCampaignPrefix(episodeTitle),
           let pageCampaign = namedCampaignPrefix(pageTitle),
           rssCampaign != pageCampaign {
            score -= 0.5
        }
        return score
    }

    nonisolated static func episodeNumbersMatch(_ episodeTitle: String, _ pageTitle: String) -> Bool {
        guard let a = episodeNumberInTitle(episodeTitle),
              let b = episodeNumberInTitle(pageTitle) else { return false }
        return a == b && looksLikeEpisodePage(pageTitle)
    }

    /// "Ep. 1 Green Teens Gone (The Moonstone Saga)" / "Episode 2: Into the Muck (…)"
    private nonisolated static func parseEpStyleTitle(
        _ title: String
    ) -> (number: Int, body: String, saga: String?)? {
        let pattern = #"(?i)^(?:ep\.?|episode)\s*(\d+)\s*[:.\-]?\s+(.+?)(?:\s*\(([^)]+)\))?\s*$"#
        guard let match = WikiTextParsing.firstMatch(pattern, in: title),
              match.numberOfRanges >= 3,
              let number = Int(WikiTextParsing.substring(match, 1, in: title)) else { return nil }
        var body = WikiTextParsing.substring(match, 2, in: title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // If body still ends with "(Saga)" because group 3 missed, strip it.
        var saga: String?
        if match.numberOfRanges >= 4 {
            let raw = WikiTextParsing.substring(match, 3, in: title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            saga = raw.isEmpty ? nil : raw
        }
        if saga == nil, let open = body.lastIndex(of: "("), body.hasSuffix(")") {
            saga = String(body[body.index(after: open)..<body.index(before: body.endIndex)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body = String(body[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard body.count >= 3 else { return nil }
        return (number, body, saga)
    }

    private nonisolated static func namedCampaignEpisodeQuery(_ title: String) -> String? {
        let pattern = #"(?i)^(.+?)\s+episode\s+(\d+)\s*:"#
        guard let match = WikiTextParsing.firstMatch(pattern, in: title),
              match.numberOfRanges >= 3 else { return nil }
        let campaign = WikiTextParsing.substring(match, 1, in: title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ep = WikiTextParsing.substring(match, 2, in: title)
        guard campaign.count >= 3 else { return nil }
        return "\(campaign) Episode \(ep)"
    }

    private nonisolated static func episodeSubtitle(_ title: String) -> String? {
        for sep in [": ", " – ", " — ", " - "] {
            if let range = title.range(of: sep) {
                let sub = String(title[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return sub.isEmpty ? nil : sub
            }
        }
        return nil
    }

    private nonisolated static func namedCampaignPrefix(_ title: String) -> String? {
        let pattern = #"(?i)^(.+?)\s+episode\s+\d+"#
        guard let match = WikiTextParsing.firstMatch(pattern, in: title),
              match.numberOfRanges >= 2 else { return nil }
        let name = WikiTextParsing.substring(match, 1, in: title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix("campaign") { return nil }
        return name.count >= 3 ? name.lowercased() : nil
    }

    private nonisolated static func matchCampaignEpisode(_ title: String) -> (campaign: Int, episode: Int)? {
        let pattern = #"(?i)campaign\s+(\d+).*?episode\s+(\d+)"#
        guard let match = WikiTextParsing.firstMatch(pattern, in: title),
              match.numberOfRanges >= 3,
              let c = Int(WikiTextParsing.substring(match, 1, in: title)),
              let e = Int(WikiTextParsing.substring(match, 2, in: title)) else { return nil }
        return (c, e)
    }

    private nonisolated static func matchBareEpisode(_ title: String) -> Int? {
        if matchCampaignEpisode(title) != nil { return nil }
        if let parsed = parseEpStyleTitle(title) { return parsed.number }
        let pattern = #"(?i)^(?:ep\.?|episode)\s*(\d+)"#
        guard let match = WikiTextParsing.firstMatch(pattern, in: title),
              match.numberOfRanges >= 2 else { return nil }
        return Int(WikiTextParsing.substring(match, 1, in: title))
    }

    private nonisolated static func episodeNumberInTitle(_ title: String) -> Int? {
        if let c = matchCampaignEpisode(title) { return c.episode }
        if let parsed = parseEpStyleTitle(title) { return parsed.number }
        let pattern = #"(?i)(?:ep\.?|episode)\s*(\d+)"#
        guard let match = WikiTextParsing.firstMatch(pattern, in: title),
              match.numberOfRanges >= 2 else { return nil }
        return Int(WikiTextParsing.substring(match, 1, in: title))
    }

    private nonisolated static func significantTokens(_ text: String) -> Set<String> {
        let stop: Set<String> = [
            "the", "a", "an", "of", "and", "or", "at", "to", "in", "on", "for",
            "episode", "ep", "campaign", "part", "with", "w", "saga"
        ]
        let cleaned = text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
        return Set(
            cleaned
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { $0.count >= 2 && !stop.contains($0) }
        )
    }

    private nonisolated static func looksLikeEpisodePage(_ title: String) -> Bool {
        WikiTextParsing.firstMatch(#"(?i)(?:^|\b)(?:ep\.?|episode)\s*\d+"#, in: title) != nil
    }
}

// MARK: - Codable API envelopes

private struct SearchResponse: Decodable {
    struct Query: Decodable {
        struct Hit: Decodable { let title: String }
        let search: [Hit]?
    }
    let query: Query?
}

private struct TitlesResponse: Decodable {
    struct Query: Decodable {
        struct Page: Decodable {
            let pageid: Int?
            let title: String
            let missing: String?
        }
        let pages: [String: Page]?
    }
    let query: Query?
}

private struct ParseResponse: Decodable {
    struct Parse: Decodable {
        let title: String
        let wikitext: Wikitext?
        struct Wikitext: Decodable {
            let value: String
            enum CodingKeys: String, CodingKey { case value = "*" }
        }
    }
    let parse: Parse?
}

private struct ParseErrorEnvelope: Decodable {
    struct APIError: Decodable { let code: String? }
    let error: APIError?
}
