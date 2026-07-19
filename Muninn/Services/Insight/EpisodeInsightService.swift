import Foundation
import Observation

/// Loads and caches wiki-backed episode insight (synopsis + character X-ray).
/// Publishes progressively: synopsis first, then each character as it finishes.
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
    /// Fill from episode details / transcript when wiki cast is thinner than this.
    nonisolated static let sparseCastFillThreshold = 2
    /// Prefer early episode speech (cast intros) over the whole transcript.
    nonisolated static let transcriptScanWindowSeconds: TimeInterval = 20 * 60

    /// True while characters are still streaming in after the synopsis shell arrived.
    var isLoadingCharacters: Bool {
        isLoading && insight != nil
    }

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
            if !Self.shouldEnrichThinCastFromTranscript(cached, episode: episode) {
                insight = cached
                if episode.localInsightPath == nil {
                    episode.localInsightPath = EpisodeInsightStore.filename(for: episode.guid)
                }
                return
            }
        }

        // Stale/missing cache, force refresh, or thin cast waiting on a new transcript.
        episode.localInsightPath = nil
        EpisodeInsightStore.remove(guid: episode.guid)

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
                try await loadProgressively(
                    mapping: map,
                    episodeTitle: title,
                    guid: guid,
                    episode: episode
                )
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

    /// Call after a transcript is saved so thin cached casts can pick up new names.
    func refreshThinCastIfNeeded(for episode: Episode) {
        guard isSupported(for: episode) else { return }
        guard let cached = EpisodeInsightStore.load(guid: episode.guid) else { return }
        guard Self.shouldEnrichThinCastFromTranscript(cached, episode: episode) else { return }
        load(for: episode, forceRefresh: true)
    }

    private func loadProgressively(
        mapping: ShowWikiMapping,
        episodeTitle: String,
        guid: String,
        episode: Episode
    ) async throws {
        let client = FandomWikiClient.shared
        guard let page = try await client.resolveEpisode(
            mapping: mapping,
            episodeTitle: episodeTitle
        ) else {
            guard activeGUID == guid else { return }
            insight = nil
            errorMessage = "No wiki page found for this episode."
            return
        }

        guard !Task.isCancelled, activeGUID == guid else { return }

        // Publish synopsis shell immediately so UI can show something useful.
        var built = EpisodeInsight(
            cacheVersion: EpisodeInsight.currentCacheVersion,
            source: mapping.sourceID,
            sourceURL: page.pageURL.absoluteString,
            attribution: mapping.attribution,
            fetchedAt: Date(),
            wikiPageTitle: page.title,
            synopsis: page.synopsis,
            characters: [],
            didScanTranscript: false
        )
        insight = built
        errorMessage = nil

        let wikiNames = Self.dedupeNames(page.characterNames, mapping: mapping)
        var mergedNames = wikiNames
        var didScanTranscript = false

        if mergedNames.count < Self.sparseCastFillThreshold {
            let detailNames = Self.detailCharacterNames(
                episodeDescription: episode.episodeDescription,
                mapping: mapping
            )
            if !detailNames.isEmpty {
                mergedNames = Self.dedupeNames(mergedNames + detailNames, mapping: mapping)
            }
        }

        if mergedNames.count < Self.sparseCastFillThreshold,
           Self.hasUsableTranscript(episode) {
            didScanTranscript = true
            let transcriptNames = await Self.transcriptCharacterNames(
                episode: episode,
                mapping: mapping
            )
            if !transcriptNames.isEmpty {
                mergedNames = Self.dedupeNames(mergedNames + transcriptNames, mapping: mapping)
            }
        }

        built.didScanTranscript = didScanTranscript

        let cappedNames = Array(mergedNames.prefix(Self.maxCharacters))
        let synopsisHint = page.synopsis.map { String($0.prefix(280)) }

        for name in cappedNames {
            if Task.isCancelled || activeGUID != guid { return }

            let character = await Self.buildCharacter(
                name: name,
                mapping: mapping,
                episodeTitle: episodeTitle,
                synopsisHint: synopsisHint,
                client: client
            )

            guard !Task.isCancelled, activeGUID == guid else { return }
            built.characters.append(character)
            insight = built

            if let artURL = character.artworkURL.flatMap(URL.init(string:)) {
                Task { await ImageCache.shared.preload(url: artURL) }
            }
        }

        guard !Task.isCancelled, activeGUID == guid else { return }
        EpisodeInsightStore.save(built, guid: guid)
        episode.localInsightPath = EpisodeInsightStore.filename(for: guid)
        insight = built
    }

    nonisolated private static func buildCharacter(
        name: String,
        mapping: ShowWikiMapping,
        episodeTitle: String,
        synopsisHint: String?,
        client: FandomWikiClient
    ) async -> InsightCharacter {
        let role = role(for: name, mapping: mapping)

        guard let profile = try? await client.fetchCharacterProfile(mapping: mapping, name: name) else {
            return InsightCharacter(
                name: name,
                role: role,
                spoilerSafeBlurb: SpoilerSafeBioRewriter.fallbackBlurb(
                    name: name,
                    role: role,
                    intro: "\(name) appears in this episode."
                ),
                wikiURL: mapping.pageURL(title: name).absoluteString,
                artworkURL: nil,
                artworkCredit: nil,
                artworkCreditURL: nil,
                facts: nil
            )
        }

        let blurb: String
        if let rewritten = await SpoilerSafeBioRewriter.rewrite(
            name: profile.name,
            role: role,
            intro: profile.intro,
            episodeTitle: episodeTitle,
            inEpisodeHint: synopsisHint
        ) {
            blurb = rewritten
        } else {
            blurb = SpoilerSafeBioRewriter.fallbackBlurb(
                name: profile.name,
                role: role,
                intro: profile.intro
            )
        }

        return InsightCharacter(
            name: profile.name,
            role: role,
            spoilerSafeBlurb: blurb,
            wikiURL: profile.pageURL.absoluteString,
            artworkURL: profile.artworkURL?.absoluteString,
            artworkCredit: profile.artworkCredit?.name,
            artworkCreditURL: profile.artworkCredit?.url,
            facts: profile.facts.isEmpty ? nil : profile.facts
        )
    }

    nonisolated private static func role(for name: String, mapping: ShowWikiMapping) -> String {
        mapping.isKnownPlayerCharacter(name) ? "PC" : "NPC"
    }

    /// Collapse aliases onto canonical wiki titles (Callie → Calliope Petrichor).
    nonisolated private static func dedupeNames(
        _ names: [String],
        mapping: ShowWikiMapping
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for name in names {
            let canon = mapping.canonicalCharacterName(for: name) ?? name
            let key = ShowWikiMapping.fold(canon)
            guard seen.insert(key).inserted else { continue }
            result.append(canon)
        }
        return result
    }

    /// Thin cached cast that hasn't been transcript-scanned yet, and a transcript is now available.
    nonisolated private static func shouldEnrichThinCastFromTranscript(
        _ cached: EpisodeInsight,
        episode: Episode
    ) -> Bool {
        guard cached.characters.count < sparseCastFillThreshold else { return false }
        guard !cached.scannedTranscript else { return false }
        return hasUsableTranscript(episode)
    }

    nonisolated private static func hasUsableTranscript(_ episode: Episode) -> Bool {
        let hasLocal = episode.localTranscriptPath != nil
            && episode.localTranscriptURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        let hasRemote = episode.transcriptURL?.nilIfBlank != nil
        return hasLocal || hasRemote
    }

    /// Scan episode show notes / description for known PCs before falling back to transcript.
    nonisolated private static func detailCharacterNames(
        episodeDescription: String?,
        mapping: ShowWikiMapping
    ) -> [String] {
        guard let raw = episodeDescription?.nilIfBlank else { return [] }
        // Regex strip is enough for name matching; avoid htmlStripped on the hot path.
        let plain = raw.htmlTagsStripped
        guard !plain.isEmpty else { return [] }
        return CharacterMentionScanner.mentions(
            of: mapping.knownPlayerCharacters,
            in: plain
        )
    }

    /// Scan early transcript text for known PCs when the wiki page names almost nobody.
    private static func transcriptCharacterNames(
        episode: Episode,
        mapping: ShowWikiMapping
    ) async -> [String] {
        guard hasUsableTranscript(episode) else { return [] }

        let segments = await TranscriptService.shared.loadSegments(for: episode)
        guard !segments.isEmpty else { return [] }

        let haystack = TranscriptTimeline(segments: segments)
            .text(from: 0, to: transcriptScanWindowSeconds)
        guard !haystack.isEmpty else { return [] }

        return CharacterMentionScanner.mentions(
            of: mapping.knownPlayerCharacters,
            in: haystack
        )
    }
}
