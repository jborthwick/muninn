import Foundation
import FeedKit
import SwiftData

/// Service for fetching and parsing podcast RSS feeds
final class FeedService {
    static let shared = FeedService()
    private init() {}

    /// Fetches and parses a podcast feed, returning a new Podcast with episodes
    func fetchPodcast(from urlString: String) async throws -> (podcast: Podcast, episodes: [Episode]) {
        guard let url = URL(string: urlString) else {
            throw FeedError.invalidURL
        }

        let parser = FeedParser(URL: url)
        let result = await withCheckedContinuation { continuation in
            parser.parseAsync { result in
                continuation.resume(returning: result)
            }
        }

        switch result {
        case .success(let feed):
            var (podcast, episodes) = try parseFeed(feed, feedURL: urlString)

            // If this is a private feed, try to find the public version
            if podcast.isPrivateFeed {
                await findPublicFeed(for: podcast)
            }

            return (podcast, episodes)
        case .failure(let error):
            throw FeedError.parsingFailed(error.localizedDescription)
        }
    }

    /// Searches iTunes for the public version of a private podcast
    private func findPublicFeed(for podcast: Podcast) async {
        do {
            let results = try await PodcastLookupService.shared.searchPodcasts(query: podcast.title)

            // Find a match with the same or very similar title
            let normalizedTitle = podcast.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            for result in results {
                let resultTitle = result.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

                // Exact match or very close
                if resultTitle == normalizedTitle ||
                   resultTitle.contains(normalizedTitle) ||
                   normalizedTitle.contains(resultTitle) {
                    if let feedURL = result.feedURL {
                        podcast.publicFeedURL = feedURL
                        return
                    }
                }
            }
        } catch {
            // Silently fail - sharing will just use the private URL
        }
    }

    /// Refreshes an existing podcast, adding new episodes
    func refreshPodcast(_ podcast: Podcast, context: ModelContext) async throws -> Int {
        let (_, newEpisodes) = try await fetchPodcast(from: podcast.feedURL)

        let existingGUIDs = Set(podcast.episodes.map { $0.guid })
        var addedCount = 0
        var newlyAddedEpisodes: [Episode] = []

        for episode in newEpisodes {
            if !existingGUIDs.contains(episode.guid) {
                episode.podcast = podcast
                podcast.episodes.append(episode)
                context.insert(episode)
                addedCount += 1
                newlyAddedEpisodes.append(episode)
            }
        }

        podcast.lastRefreshed = Date()

        // Auto-download new episodes if enabled for this podcast
        if podcast.autoDownloadNewEpisodes {
            for episode in newlyAddedEpisodes {
                DownloadManager.shared.download(episode)
            }

            // Enforce per-podcast limit after downloads start
            DownloadCleanupService.shared.enforcePerPodcastLimit(for: podcast, context: context)
        }

        return addedCount
    }

    private func parseFeed(_ feed: Feed, feedURL: String) throws -> (podcast: Podcast, episodes: [Episode]) {
        switch feed {
        case .rss(let rssFeed):
            return parseRSSFeed(rssFeed, feedURL: feedURL)
        case .atom(let atomFeed):
            return parseAtomFeed(atomFeed, feedURL: feedURL)
        case .json(let jsonFeed):
            return parseJSONFeed(jsonFeed, feedURL: feedURL)
        }
    }

    private func parseRSSFeed(_ feed: RSSFeed, feedURL: String) -> (podcast: Podcast, episodes: [Episode]) {
        let podcast = Podcast(
            feedURL: feedURL,
            title: feed.title ?? "Untitled Podcast",
            author: feed.iTunes?.iTunesAuthor ?? feed.managingEditor,
            artworkURL: feed.iTunes?.iTunesImage?.attributes?.href ?? feed.image?.url,
            podcastDescription: feed.description
        )

        let episodes = (feed.items ?? []).compactMap { item -> Episode? in
            guard let audioURL = item.enclosure?.attributes?.url ?? findAudioURL(in: item) else {
                return nil
            }

            let guid = item.guid?.value ?? audioURL

            return Episode(
                guid: guid,
                title: item.title ?? "Untitled Episode",
                audioURL: audioURL,
                episodeDescription: item.description ?? item.content?.contentEncoded,
                duration: parseDuration(item.iTunes?.iTunesDuration),
                publishedDate: item.pubDate,
                artworkURL: item.iTunes?.iTunesImage?.attributes?.href
            )
        }

        return (podcast, episodes)
    }

    private func parseAtomFeed(_ feed: AtomFeed, feedURL: String) -> (podcast: Podcast, episodes: [Episode]) {
        let podcast = Podcast(
            feedURL: feedURL,
            title: feed.title ?? "Untitled Podcast",
            author: feed.authors?.first?.name,
            artworkURL: feed.logo,
            podcastDescription: feed.subtitle?.value
        )

        let episodes = (feed.entries ?? []).compactMap { entry -> Episode? in
            guard let audioURL = entry.links?.first(where: {
                $0.attributes?.type?.contains("audio") == true
            })?.attributes?.href else {
                return nil
            }

            return Episode(
                guid: entry.id ?? audioURL,
                title: entry.title ?? "Untitled Episode",
                audioURL: audioURL,
                episodeDescription: entry.summary?.value ?? entry.content?.value,
                publishedDate: entry.published ?? entry.updated
            )
        }

        return (podcast, episodes)
    }

    private func parseJSONFeed(_ feed: JSONFeed, feedURL: String) -> (podcast: Podcast, episodes: [Episode]) {
        let podcast = Podcast(
            feedURL: feedURL,
            title: feed.title ?? "Untitled Podcast",
            author: feed.author?.name,
            artworkURL: feed.icon ?? feed.favicon,
            podcastDescription: feed.description
        )

        let episodes = (feed.items ?? []).compactMap { item -> Episode? in
            guard let audioURL = item.attachments?.first(where: {
                $0.mimeType?.contains("audio") == true
            })?.url else {
                return nil
            }

            return Episode(
                guid: item.id ?? audioURL,
                title: item.title ?? "Untitled Episode",
                audioURL: audioURL,
                episodeDescription: item.contentHtml ?? item.contentText,
                duration: item.attachments?.first?.durationInSeconds.map { TimeInterval($0) },
                publishedDate: item.datePublished
            )
        }

        return (podcast, episodes)
    }

    private func findAudioURL(in item: RSSFeedItem) -> String? {
        // Some feeds put audio in media content
        if let mediaContent = item.media?.mediaContents?.first(where: {
            $0.attributes?.type?.contains("audio") == true
        }) {
            return mediaContent.attributes?.url
        }
        return nil
    }

    private func parseDuration(_ duration: TimeInterval?) -> TimeInterval? {
        duration
    }

    private func parseDate(_ dateString: String?) -> Date? {
        guard let dateString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
    }
}

enum FeedError: LocalizedError {
    case invalidURL
    case parsingFailed(String)
    case noAudioContent

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid feed URL"
        case .parsingFailed(let reason):
            return "Failed to parse feed: \(reason)"
        case .noAudioContent:
            return "No audio content found in feed"
        }
    }
}
