import Foundation

/// Service for resolving podcast URLs and searching for podcasts
final class PodcastLookupService {
    static let shared = PodcastLookupService()
    private init() {}

    // MARK: - URL Resolution

    /// Resolves various podcast URL formats to an RSS feed URL
    func resolveToRSSFeed(url urlString: String) async throws -> String {
        let normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Already an RSS feed URL
        if isLikelyRSSFeed(normalized) {
            return normalized
        }

        // Apple Podcasts URL
        if let appleID = extractApplePodcastID(from: normalized) {
            return try await resolveApplePodcast(id: appleID)
        }

        // Pocket Casts URL
        if normalized.contains("pca.st") {
            return try await resolvePocketCasts(url: normalized)
        }

        // Overcast URL (bonus)
        if normalized.contains("overcast.fm") {
            if let appleID = extractOvercastAppleID(from: normalized) {
                return try await resolveApplePodcast(id: appleID)
            }
        }

        // Spotify URL
        if normalized.contains("spotify.com") {
            return try await resolveSpotify(url: normalized)
        }

        // Assume it's a direct RSS URL
        return normalized
    }

    // MARK: - Search

    /// Search for podcasts using Apple's iTunes Search API
    func searchPodcasts(query: String) async throws -> [PodcastSearchResult] {
        guard !query.isEmpty else { return [] }

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "https://itunes.apple.com/search?term=\(encoded)&media=podcast&limit=25"

        guard let url = URL(string: urlString) else {
            throw LookupError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(iTunesSearchResponse.self, from: data)

        return response.results.map { result in
            PodcastSearchResult(
                id: String(result.collectionId),
                title: result.collectionName,
                author: result.artistName,
                artworkURL: result.artworkUrl600 ?? result.artworkUrl100,
                feedURL: result.feedUrl
            )
        }
    }

    // MARK: - Apple Podcasts Resolution

    private func resolveApplePodcast(id: String) async throws -> String {
        let urlString = "https://itunes.apple.com/lookup?id=\(id)&entity=podcast"

        guard let url = URL(string: urlString) else {
            throw LookupError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(iTunesLookupResponse.self, from: data)

        guard let result = response.results.first, let feedURL = result.feedUrl else {
            throw LookupError.feedNotFound
        }

        return feedURL
    }

    private func extractApplePodcastID(from url: String) -> String? {
        // Format: https://podcasts.apple.com/us/podcast/podcast-name/id1234567890
        // Or: https://itunes.apple.com/podcast/id1234567890
        if let range = url.range(of: "/id") {
            let afterID = url[range.upperBound...]
            let id = afterID.prefix(while: { $0.isNumber })
            if !id.isEmpty {
                return String(id)
            }
        }
        return nil
    }

    // MARK: - Pocket Casts Resolution

    private func resolvePocketCasts(url urlString: String) async throws -> String {
        // Pocket Casts URLs can be:
        // https://pca.st/podcast/abc123
        // https://pca.st/abc123
        // https://pockets.casts.com/podcasts/abc123

        guard let url = URL(string: urlString) else {
            throw LookupError.invalidURL
        }

        // Fetch the page and look for RSS feed in meta tags or page content
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        // Check for redirect - Pocket Casts might redirect to the actual podcast page
        if let httpResponse = response as? HTTPURLResponse,
           let location = httpResponse.value(forHTTPHeaderField: "Location") {
            return try await resolvePocketCasts(url: location)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw LookupError.feedNotFound
        }

        // Look for RSS feed URL in the page
        if let feedURL = extractRSSFromHTML(html) {
            return feedURL
        }

        // Look for Apple Podcasts link and resolve that
        if let appleURL = extractApplePodcastsLink(from: html),
           let appleID = extractApplePodcastID(from: appleURL) {
            return try await resolveApplePodcast(id: appleID)
        }

        throw LookupError.feedNotFound
    }

    private func extractRSSFromHTML(_ html: String) -> String? {
        // Look for RSS link in meta tags
        // <link rel="alternate" type="application/rss+xml" href="..." />
        let patterns = [
            #"<link[^>]*type=["\']application/rss\+xml["\'][^>]*href=["\']([^"\']+)["\']"#,
            #"<link[^>]*href=["\']([^"\']+)["\'][^>]*type=["\']application/rss\+xml["\']"#,
            #"["\']feedUrl["\']\s*:\s*["\']([^"\']+)["\']"#,
            #"rss[_-]?feed[_-]?url["\']?\s*[:=]\s*["\']([^"\']+)["\']"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                return String(html[range])
            }
        }

        return nil
    }

    private func extractApplePodcastsLink(from html: String) -> String? {
        let pattern = #"https://podcasts\.apple\.com/[^"'\s]+"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range, in: html) {
            return String(html[range])
        }
        return nil
    }

    // MARK: - Overcast Resolution

    private func extractOvercastAppleID(from url: String) -> String? {
        // Format: https://overcast.fm/itunes1234567890
        if let range = url.range(of: "itunes") {
            let afterItunes = url[range.upperBound...]
            let id = afterItunes.prefix(while: { $0.isNumber })
            if !id.isEmpty {
                return String(id)
            }
        }
        return nil
    }

    // MARK: - Spotify Resolution

    private func resolveSpotify(url urlString: String) async throws -> String {
        // Spotify URLs can be:
        // https://open.spotify.com/show/abc123xyz
        // https://open.spotify.com/episode/abc123xyz (episode link - extract show from it)
        
        guard let url = URL(string: urlString) else {
            throw LookupError.invalidURL
        }
        
        // Fetch the Spotify page
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        
        guard let html = String(data: data, encoding: .utf8) else {
            throw LookupError.feedNotFound
        }
        
        // Try to extract podcast name from the page
        let podcastName = extractSpotifyPodcastName(from: html)
        
        guard let podcastName = podcastName, !podcastName.isEmpty else {
            throw LookupError.networkError("Could not extract podcast name from Spotify page")
        }
        
        // Search for the podcast on Apple Podcasts
        let searchResults = try await searchPodcasts(query: podcastName)
        
        // Find best match
        let normalizedName = podcastName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        for result in searchResults {
            let resultName = result.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Look for exact or very close match
            if resultName == normalizedName || 
               resultName.contains(normalizedName) ||
               normalizedName.contains(resultName) {
                if let feedURL = result.feedURL {
                    return feedURL
                }
            }
        }
        
        // If no exact match, return the first result's feed URL if available
        if let firstResult = searchResults.first, let feedURL = firstResult.feedURL {
            return feedURL
        }
        
        throw LookupError.feedNotFound
    }
    
    private func extractSpotifyPodcastName(from html: String) -> String? {
        // Try multiple patterns to extract the podcast name
        let patterns = [
            // Open Graph meta tag
            #"<meta\s+property=["\']og:title["\']\s+content=["\']([^"\']+)["\']"#,
            #"<meta\s+content=["\']([^"\']+)["\']\s+property=["\']og:title["\']"#,
            // Twitter meta tag
            #"<meta\s+name=["\']twitter:title["\']\s+content=["\']([^"\']+)["\']"#,
            // Title tag
            #"<title>([^<]+)</title>"#,
            // JSON-LD structured data
            #"["\']name["\']\s*:\s*["\']([^"\']+)["\']"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                var name = String(html[range])
                
                // Clean up the name
                name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Remove " - Spotify" or similar suffixes
                if let dashRange = name.range(of: " - ") {
                    name = String(name[..<dashRange.lowerBound])
                }
                if let pipeRange = name.range(of: " | ") {
                    name = String(name[..<pipeRange.lowerBound])
                }
                
                // Decode HTML entities
                name = name.replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&#39;", with: "'")
                
                if !name.isEmpty {
                    return name
                }
            }
        }
        
        return nil
    }

    private func extractSpotifyShowID(from url: String) -> String? {
        // Format: https://open.spotify.com/show/abc123xyz
        // or: spotify:show:abc123xyz
        
        // Handle web URL format
        if let range = url.range(of: "/show/") {
            let afterShow = url[range.upperBound...]
            let id = afterShow.prefix(while: { $0 != "/" && $0 != "?" })
            if !id.isEmpty {
                return String(id)
            }
        }
        
        // Handle URI format (spotify:show:abc123xyz)
        if let range = url.range(of: "show:") {
            let afterShow = url[range.upperBound...]
            let id = afterShow.prefix(while: { $0 != ":" && $0 != "/" && $0 != "?" })
            if !id.isEmpty {
                return String(id)
            }
        }
        
        return nil
    }

    // MARK: - Helpers

    private func isLikelyRSSFeed(_ url: String) -> Bool {
        let lowercased = url.lowercased()
        return lowercased.contains("/rss") ||
               lowercased.contains("/feed") ||
               lowercased.contains(".rss") ||
               lowercased.contains(".xml") ||
               lowercased.contains("format=rss") ||
               lowercased.contains("feed.") ||
               lowercased.contains("/atom")
    }
}

// MARK: - Models

struct PodcastSearchResult: Identifiable {
    let id: String
    let title: String
    let author: String?
    let artworkURL: String?
    let feedURL: String?
}

enum LookupError: LocalizedError {
    case invalidURL
    case feedNotFound
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .feedNotFound:
            return "Could not find RSS feed for this podcast"
        case .networkError(let message):
            return message
        }
    }
}

// MARK: - iTunes API Response Models

private struct iTunesSearchResponse: Codable {
    let resultCount: Int
    let results: [iTunesPodcast]
}

private struct iTunesLookupResponse: Codable {
    let resultCount: Int
    let results: [iTunesPodcast]
}

private struct iTunesPodcast: Codable {
    let collectionId: Int
    let collectionName: String
    let artistName: String?
    let artworkUrl100: String?
    let artworkUrl600: String?
    let feedUrl: String?
}
