import Foundation
import SwiftData

@Model
final class Podcast {
    @Attribute(.unique) var feedURL: String
    var title: String
    var author: String?
    var artworkURL: String?
    var podcastDescription: String?

    // iTunes/Apple Podcasts ID for sharing
    var itunesID: String?

    // Public feed URL for sharing (fallback if no iTunes ID and this is a private feed)
    var publicFeedURL: String?

    // Per-podcast settings
    var playbackSpeedOverride: Double?  // nil = use global setting
    var autoDownloadNewEpisodes: Bool = false  // Auto-download new episodes when refreshed

    /// Whether this podcast uses a private feed URL (Patreon, Substack, Supercast, etc.)
    var isPrivateFeed: Bool {
        guard let url = URL(string: feedURL) else { return false }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""

        // Known private/premium feed hosts
        if host.contains("patreon.com") ||
           host.contains("substack.com") ||
           host.contains("supercast.com") ||
           host.contains("supportingcast.fm") ||
           host.contains("glow.fm") {
            return true
        }

        // URL contains auth tokens
        if query.contains("auth=") || query.contains("token=") || query.contains("key=") {
            return true
        }

        // Path contains private indicators
        if path.contains("/private/") || path.contains("/premium/") || path.contains("/member/") {
            return true
        }

        return false
    }

    /// The URL to use when sharing - prefers iTunes URL, falls back to public feed URL or feed URL
    var shareURL: String {
        // Prefer iTunes URL for sharing (more universal)
        if let itunesID {
            return "https://podcasts.apple.com/podcast/id\(itunesID)"
        }
        // Fall back to public feed URL (for private feeds without iTunes ID)
        if let publicFeedURL {
            return publicFeedURL
        }
        // Last resort: use the feed URL (but not if it's a private feed with auth tokens)
        if !isPrivateFeed {
            return feedURL
        }
        // Private feed with no public alternative - return empty to prevent sharing
        return ""
    }

    /// Whether this podcast can be shared
    var canShare: Bool {
        !shareURL.isEmpty
    }

    // Relationships
    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode] = []

    @Relationship(inverse: \Folder.podcasts)
    var folders: [Folder] = []

    // Metadata
    var dateAdded: Date = Date()
    var lastRefreshed: Date?

    // HTTP caching headers for conditional requests
    var feedETag: String?
    var feedLastModified: String?

    init(
        feedURL: String,
        title: String,
        author: String? = nil,
        artworkURL: String? = nil,
        podcastDescription: String? = nil
    ) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.artworkURL = artworkURL
        self.podcastDescription = podcastDescription
    }
}
