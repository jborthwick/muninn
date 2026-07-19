import Foundation

/// Cached wiki-backed insight for an episode (synopsis + character cards).
struct EpisodeInsight: Codable, Equatable {
    /// Bump when matching/parsing changes so on-disk JSON is discarded.
    /// 9 = artist credits + clearer wiki sourcing.
    static let currentCacheVersion = 9

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
    /// Artist name from wiki caption when available.
    var artworkCredit: String?
    /// External (or wiki) URL for the artist credit.
    var artworkCreditURL: String?
    /// Compact X-ray facts (Class, Species, Player, Pronouns).
    var facts: [InsightCharacterFact]?

    var hasFacts: Bool {
        guard let facts else { return false }
        return !facts.isEmpty
    }

    var hasArtworkCredit: Bool {
        guard let artworkCredit else { return false }
        return !artworkCredit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct InsightCharacterFact: Codable, Equatable, Identifiable {
    var id: String { label }
    var label: String
    var value: String
}
