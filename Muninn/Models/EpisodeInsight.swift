import Foundation

/// Cached wiki-backed insight for an episode (synopsis + character cards).
struct EpisodeInsight: Codable, Equatable {
    /// Bump when matching/parsing changes so on-disk JSON is discarded.
    /// 5 = sanitize height quotes so FM blurbs don't truncate on 6'6".
    static let currentCacheVersion = 5

    /// Absent/older than `currentCacheVersion` → cache miss + delete.
    var cacheVersion: Int?
    var source: String
    var sourceURL: String?
    var attribution: String
    var fetchedAt: Date
    var wikiPageTitle: String?
    var synopsis: String?
    var characters: [InsightCharacter]

    var isCurrentCache: Bool {
        cacheVersion == Self.currentCacheVersion
    }

    var hasSynopsis: Bool {
        guard let synopsis else { return false }
        return !synopsis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCharacters: Bool { !characters.isEmpty }
}

struct InsightCharacter: Codable, Equatable, Identifiable {
    var id: String { name.lowercased() }
    var name: String
    /// PC, NPC, or mentioned
    var role: String?
    var spoilerSafeBlurb: String
    var wikiURL: String?
    var artworkURL: String?
}
