import Foundation
import Observation

/// Loads and caches wiki-backed episode insight (synopsis + character X-ray).
@MainActor
@Observable
final class EpisodeInsightService {
    static let shared = EpisodeInsightService()

    private(set) var insight: EpisodeInsight?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var mapping: ShowWikiMapping?

    private var activeGUID: String?
    private var loadTask: Task<Void, Never>?

    nonisolated static let maxCharacters = 12

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    func reset() {
        cancel()
        insight = nil
        errorMessage = nil
        mapping = nil
        activeGUID = nil
        isLoading = false
    }

    /// Returns whether this episode's podcast has a wiki mapping.
    func isSupported(for episode: Episode) -> Bool {
        guard let podcast = episode.podcast else { return false }
        return ShowWikiRegistry.isMapped(podcast)
    }

    func load(for episode: Episode, forceRefresh: Bool = false) {
        guard let podcast = episode.podcast,
              let mapping = ShowWikiRegistry.mapping(for: podcast) else {
            reset()
            return
        }

        if activeGUID != episode.guid {
            insight = nil
            errorMessage = nil
        }

        self.mapping = mapping
        activeGUID = episode.guid

        if !forceRefresh, let cached = EpisodeInsightStore.load(guid: episode.guid) {
            insight = cached
            if episode.localInsightPath == nil {
                episode.localInsightPath = EpisodeInsightStore.filename(for: episode.guid)
            }
            return
        }

        // Stale/missing cache (or force refresh): drop path until rewrite succeeds.
        if forceRefresh || episode.localInsightPath != nil {
            episode.localInsightPath = nil
            EpisodeInsightStore.remove(guid: episode.guid)
        }

        loadTask?.cancel()
        isLoading = true
        errorMessage = nil

        let guid = episode.guid
        let title = episode.title
        let map = mapping

        loadTask = Task {
            defer {
                if activeGUID == guid {
                    isLoading = false
                }
            }
            do {
                let built = try await Self.buildInsight(
                    mapping: map,
                    episodeTitle: title
                )
                guard !Task.isCancelled, activeGUID == guid else { return }
                if let built {
                    EpisodeInsightStore.save(built, guid: guid)
                    episode.localInsightPath = EpisodeInsightStore.filename(for: guid)
                    insight = built
                    errorMessage = nil
                } else {
                    insight = nil
                    errorMessage = "No wiki page found for this episode."
                }
            } catch is CancellationError {
                // Superseded by another load or intentional cancel — keep prior insight.
            } catch let urlError as URLError where urlError.code == .cancelled {
                // URLSession maps Task cancel to URLError.cancelled, not CancellationError.
            } catch {
                guard !Task.isCancelled, activeGUID == guid else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    nonisolated private static func buildInsight(
        mapping: ShowWikiMapping,
        episodeTitle: String
    ) async throws -> EpisodeInsight? {
        let client = FandomWikiClient.shared
        guard let page = try await client.resolveEpisode(
            mapping: mapping,
            episodeTitle: episodeTitle
        ) else {
            return nil
        }

        let cappedNames = Array(Self.dedupeNames(
            Array(page.characterNames.prefix(maxCharacters * 2)),
            knownPCs: mapping.knownPlayerCharacters
        ).prefix(maxCharacters))
        let synopsisHint = page.synopsis.map { String($0.prefix(280)) }
        var characters: [InsightCharacter] = []

        for name in cappedNames {
            if Task.isCancelled { break }
            let role = role(for: name, mapping: mapping)
            var blurb = ""
            var wikiURL = mapping.pageURL(title: name).absoluteString

            if let intro = try? await client.fetchCharacterIntro(mapping: mapping, name: name) {
                wikiURL = intro.pageURL.absoluteString
                if let rewritten = await SpoilerSafeBioRewriter.rewrite(
                    name: intro.name,
                    role: role,
                    intro: intro.intro,
                    episodeTitle: episodeTitle,
                    inEpisodeHint: synopsisHint
                ) {
                    blurb = rewritten
                } else {
                    blurb = SpoilerSafeBioRewriter.fallbackBlurb(
                        name: intro.name,
                        role: role,
                        intro: intro.intro
                    )
                }
            } else {
                blurb = SpoilerSafeBioRewriter.fallbackBlurb(
                    name: name,
                    role: role,
                    intro: "\(name) appears in this episode."
                )
            }

            characters.append(
                InsightCharacter(
                    name: name,
                    role: role,
                    spoilerSafeBlurb: blurb,
                    wikiURL: wikiURL,
                    artworkURL: nil
                )
            )
        }

        return EpisodeInsight(
            cacheVersion: EpisodeInsight.currentCacheVersion,
            source: mapping.sourceID,
            sourceURL: page.pageURL.absoluteString,
            attribution: mapping.attribution,
            fetchedAt: Date(),
            wikiPageTitle: page.title,
            synopsis: page.synopsis,
            characters: characters
        )
    }

    nonisolated private static func role(for name: String, mapping: ShowWikiMapping) -> String {
        let lower = name.lowercased()
        for pc in mapping.knownPlayerCharacters {
            let pcLower = pc.lowercased()
            if lower == pcLower || lower.hasPrefix(pcLower) || pcLower.hasPrefix(lower) {
                return "PC"
            }
        }
        return "NPC"
    }

    /// Collapse aliases onto the longest known PC name when possible.
    nonisolated private static func dedupeNames(_ names: [String], knownPCs: [String]) -> [String] {
        let canonicalPCs = knownPCs.sorted { $0.count > $1.count }
        var result: [String] = []
        var seen = Set<String>()

        func canonical(_ name: String) -> String {
            let lower = name.lowercased()
            for pc in canonicalPCs {
                let pcLower = pc.lowercased()
                if lower == pcLower || lower.hasPrefix(pcLower) || pcLower.hasPrefix(lower) {
                    // Prefer full PC name over short alias
                    return canonicalPCs.first(where: {
                        $0.lowercased() == pcLower || $0.lowercased().hasPrefix(pcLower)
                    }) ?? pc
                }
            }
            return name
        }

        for name in names {
            let canon = canonical(name)
            let key = canon.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(canon)
        }
        return result
    }
}
