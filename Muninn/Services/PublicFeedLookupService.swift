import Foundation

/// Finds the public Apple Podcasts listing for a private/premium feed (Patreon,
/// Supercast, etc.) so it can be shared without exposing the private feed URL.
///
/// Runs at most once per podcast: once a lookup completes (match or no match) it is
/// recorded in `Podcast.publicFeedLookupAttempted`, so refreshes and repeat visits to
/// the podcast page don't keep hitting the iTunes Search API with titles like
/// "NaddPod Patreon Exclusives" that never match a public listing.
@MainActor
final class PublicFeedLookupService {
    static let shared = PublicFeedLookupService()
    private init() {}

    /// Lookups currently running, keyed by feed URL, so concurrent callers
    /// (e.g. page appear + Share tap) share one lookup instead of starting two.
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// Whether a lookup would do anything for this podcast.
    func needsLookup(_ podcast: Podcast) -> Bool {
        podcast.isPrivateFeed &&
            podcast.itunesID == nil &&
            podcast.publicFeedURL == nil &&
            !podcast.publicFeedLookupAttempted
    }

    /// Looks up the public listing if this podcast hasn't been checked yet.
    /// Sets `publicFeedURL` on a match. Caller is responsible for saving the context.
    func lookupIfNeeded(for podcast: Podcast) async {
        let key = podcast.feedURL
        if let running = inFlight[key] {
            await running.value
            return
        }
        guard needsLookup(podcast) else { return }

        let title = podcast.title
        let task = Task {
            let outcome = await Self.searchPublicURL(title: title, feedURL: key)
            if let url = outcome.url {
                podcast.publicFeedURL = url
            }
            // Only record the attempt if iTunes actually answered; a network failure
            // (e.g. offline) leaves the podcast eligible for one more try later.
            if outcome.completed {
                podcast.publicFeedLookupAttempted = true
            }
        }
        inFlight[key] = task
        await task.value
        inFlight[key] = nil
    }

    // MARK: - Search

    private struct Outcome {
        var url: String?
        /// True if at least one search request returned a response.
        var completed: Bool
    }

    private static func searchPublicURL(title: String, feedURL: String) async -> Outcome {
        let logger = AppLogger.feed
        logger.info("Looking up public feed for: \(title)")
        logger.info("Private feed URL: \(feedURL)")

        let queries = searchQueries(for: title)
        var completed = false

        for (queryIndex, searchQuery) in queries.enumerated() {
            logger.info("Trying search query: \(searchQuery)")

            let results: [PodcastSearchResult]
            do {
                results = try await PodcastLookupService.shared.searchPodcasts(query: searchQuery)
                completed = true
            } catch {
                logger.error("Search failed: \(error.localizedDescription)")
                continue
            }
            logger.info("Found \(results.count) search results")
            if results.isEmpty { continue }

            // Try to find best match using word overlap
            let titleWords = words(in: searchQuery)
            var bestMatch: (result: PodcastSearchResult, score: Int)?

            for result in results {
                let resultWords = words(in: result.title)
                let overlap = titleWords.intersection(resultWords).count
                let score = overlap * 2 - abs(titleWords.count - resultWords.count)
                logger.info("Result: '\(result.title)' - overlap: \(overlap), score: \(score)")

                if result.feedURL != nil && score > 0 && score > (bestMatch?.score ?? Int.min) {
                    bestMatch = (result, score)
                }
            }

            if let match = bestMatch {
                logger.info("Best match: '\(match.result.title)' with score \(match.score)")
                return Outcome(url: appleURL(for: match.result), completed: true)
            }

            // Fallback for single-word abbreviation queries (e.g. "NaddPod"):
            // word-overlap scoring can never work when the query is an opaque
            // abbreviation of the full show title. If this is the last query
            // and it's a single substantive word, trust iTunes' own ranking and
            // accept the top result.
            let isLastQuery = queryIndex == queries.count - 1
            if isLastQuery && titleWords.count == 1,
               let word = titleWords.first, word.count >= 4,
               let topResult = results.first(where: { $0.feedURL != nil }) {
                logger.info("Accepting top iTunes result for abbreviation query '\(searchQuery)': '\(topResult.title)'")
                return Outcome(url: appleURL(for: topResult), completed: true)
            }
        }

        logger.warning("No matching public feed found after trying all queries")
        return Outcome(url: nil, completed: completed)
    }

    /// Cleans private-feed suffixes from the title, then returns progressively
    /// shorter queries (handles tier names like "If Books Could Kill Mile High Club").
    private static func searchQueries(for title: String) -> [String] {
        var cleanTitle = title

        // Remove "(private feed for email@example.com)" pattern
        if let range = cleanTitle.range(of: #"\s*\(private feed.*\)"#, options: [.regularExpression, .caseInsensitive]) {
            cleanTitle = String(cleanTitle[..<range.lowerBound])
        }

        // Remove parenthetical suffixes like "(Premium)" or "(Subscriber)"
        if let range = cleanTitle.range(of: #"\s*\((premium|subscriber|member|patron).*\)"#, options: [.regularExpression, .caseInsensitive]) {
            cleanTitle = String(cleanTitle[..<range.lowerBound])
        }

        // Remove bare (non-parenthetical) private/member suffixes, e.g.
        // "Patreon Exclusives", "Patreon Feed", "Members Only", "Subscriber Exclusive"
        if let range = cleanTitle.range(of: #"\s+(patreon|patron|subscribers?|members?)(\s+(exclusives?|feed|only|content))?\s*$"#,
                                        options: [.regularExpression, .caseInsensitive]) {
            cleanTitle = String(cleanTitle[..<range.lowerBound])
        }

        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        var queries = [cleanTitle]
        let titleWords = cleanTitle.split(separator: " ").map(String.init)
        if titleWords.count >= 2 {
            // Try removing last 1, 2, 3 words (keeping at least 1)
            for dropCount in 1...min(3, titleWords.count - 1) {
                let shortened = titleWords.dropLast(dropCount).joined(separator: " ")
                if shortened.count >= 3 {
                    queries.append(shortened)
                }
            }
        }

        // De-duplicate while preserving order; drop empties
        var seen = Set<String>()
        return queries.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    private static func appleURL(for result: PodcastSearchResult) -> String {
        "https://podcasts.apple.com/podcast/id\(result.id)"
    }
}
