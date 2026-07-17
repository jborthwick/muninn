import Foundation
import NaturalLanguage
import FoundationModels
import SwiftData
import os

@MainActor
@Observable
final class ChapterService {
    static let shared = ChapterService()
    private init() {}

    private let logger = Logger(subsystem: "com.muninn", category: "ChapterService")

    // MARK: - Observable State

    private(set) var chapters: [Chapter] = []
    private(set) var overview: String = ""
    private(set) var isGenerating = false
    private(set) var generationStatus: String = ""
    private(set) var error: String?
    private(set) var generatingEpisodeGUID: String?
    /// Episode whose chapters are currently loaded into `chapters` (Now Playing UI).
    private(set) var loadedEpisodeGUID: String?
    private var errorEpisodeGUID: String?
    private(set) var lastChapterDebug: ChapterGenerationDebugInfo?
    private(set) var lastChapterDebugEpisodeGUID: String?

    func isGenerating(for episodeGUID: String) -> Bool {
        isGenerating && generatingEpisodeGUID == episodeGUID
    }

    func errorMessage(for episodeGUID: String) -> String? {
        guard errorEpisodeGUID == episodeGUID else { return nil }
        return error
    }

    // MARK: - Availability

    nonisolated static var isSupported: Bool { true }

    nonisolated static var titlesSupported: Bool {
        SystemLanguageModel.default.isAvailable
    }

    // MARK: - Public API

    func load(for episode: Episode) {
        loadedEpisodeGUID = episode.guid
        error = nil
        errorEpisodeGUID = nil

        // Pre-merge installs kept summaries in a separate file. Wipe both rather than migrate.
        let hadLegacySummary = episode.localSummaryPath != nil
        discardObsoleteSummaryArtifacts(for: episode)

        if hadLegacySummary, let url = episode.localChaptersURL {
            try? FileManager.default.removeItem(at: url)
            episode.localChaptersPath = nil
            try? episode.modelContext?.save()
            chapters = []
            overview = ""
            return
        }

        guard let url = episode.localChaptersURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(ChaptersDocument.self, from: data) else {
            chapters = []
            overview = ""
            return
        }

        chapters = document.chapters
        overview = document.overview ?? ""
    }

    func clear() {
        chapters = []
        overview = ""
        loadedEpisodeGUID = nil
        error = nil
        errorEpisodeGUID = nil
        generationStatus = ""
        lastChapterDebug = nil
        lastChapterDebugEpisodeGUID = nil
    }

    func clearChapterDebug() {
        lastChapterDebug = nil
        lastChapterDebugEpisodeGUID = nil
    }

    /// Latest generation debug for this episode, or a snapshot from persisted chapter summaries.
    func chapterDebug(episodeGUID: String, chapters: [Chapter], overview: String) -> ChapterGenerationDebugInfo? {
        if lastChapterDebugEpisodeGUID == episodeGUID, let lastChapterDebug {
            return lastChapterDebug
        }
        return persistedChapterDebug(episodeGUID: episodeGUID, chapters: chapters, overview: overview)
    }

    private func persistedChapterDebug(
        episodeGUID: String,
        chapters: [Chapter],
        overview: String
    ) -> ChapterGenerationDebugInfo? {
        let summarized = chapters.filter { !($0.summary ?? "").isEmpty }
        guard !summarized.isEmpty else { return nil }

        let beats = chapters.enumerated().map { index, chapter in
            ChapterBeatDebugEntry(
                index: index,
                startTime: chapter.startTime,
                endTime: chapter.endTime,
                title: chapter.title,
                summary: chapter.summary ?? "",
                source: "persisted",
                flaggedRollCall: false,
                transcriptCharacters: 0,
                excerptPreview: "",
                usedChunking: false,
                error: nil
            )
        }

        return ChapterGenerationDebugInfo(
            generatedAt: Date(),
            episodeGUID: episodeGUID,
            source: "persisted",
            beats: beats,
            overview: overview,
            succeeded: true
        )
    }

    private func storeChapterDebug(_ debug: ChapterGenerationDebugInfo, episodeGUID: String) {
        lastChapterDebug = debug
        lastChapterDebugEpisodeGUID = episodeGUID
    }

    /// Old separate Summaries/ JSON is obsolete — delete and forget.
    private func discardObsoleteSummaryArtifacts(for episode: Episode) {
        if let url = episode.localSummaryURL {
            try? FileManager.default.removeItem(at: url)
        }
        if episode.localSummaryPath != nil {
            episode.localSummaryPath = nil
            try? episode.modelContext?.save()
        }
    }

    /// Generate chapters from show notes (fast path) or transcript (boundaries + titles).
    @discardableResult
    func generate(episode: Episode, context: ModelContext) async -> Bool {
        guard !isGenerating else { return false }

        var debug = ChapterGenerationDebugInfo()
        debug.generatedAt = Date()
        debug.episodeTitle = episode.title
        debug.episodeGUID = episode.guid
        debug.foundationModelAvailable = Self.titlesSupported

        if let oldURL = episode.localChaptersURL {
            try? FileManager.default.removeItem(at: oldURL)
        }
        discardObsoleteSummaryArtifacts(for: episode)
        episode.localChaptersPath = nil
        if loadedEpisodeGUID == episode.guid {
            chapters = []
            overview = ""
            TranscriptSummaryService.shared.clear()
        }

        isGenerating = true
        error = nil
        errorEpisodeGUID = nil
        generatingEpisodeGUID = episode.guid
        PendingWorkStore.addChapter(guid: episode.guid)
        EpisodeProcessingBackgroundManager.shared.notifyWorkStateChanged()

        defer {
            isGenerating = false
            generationStatus = ""
            generatingEpisodeGUID = nil
            PendingWorkStore.removeChapter(guid: episode.guid)
            storeChapterDebug(debug, episodeGUID: episode.guid)
            EpisodeProcessingBackgroundManager.shared.notifyWorkStateChanged()
        }

        let transcriptService = TranscriptService.shared
        await transcriptService.load(for: episode)
        let segments = transcriptService.segments
        let duration = episode.duration ?? segments.last?.endTime ?? 0
        debug.episodeDuration = duration
        debug.segmentCount = segments.count

        // Fast path: chapters already in episode show notes.
        if let rssChapters = ChapterShowNotesParser.chapters(from: episode.episodeDescription, duration: duration) {
            generationStatus = "Using show note chapters…"
            debug.source = "show_notes"
            debug.boundaryCount = rssChapters.count
            debug.boundariesDescription = rssChapters
                .map { ChapterTitleGenerator.formatTime($0.startTime) }
                .joined(separator: ", ")
            debug.beats = rssChapters.enumerated().map { index, chapter in
                ChapterBeatDebugEntry(
                    index: index,
                    startTime: chapter.startTime,
                    endTime: chapter.endTime,
                    title: chapter.title,
                    summary: "",
                    source: "show_notes",
                    flaggedRollCall: false,
                    transcriptCharacters: 0,
                    excerptPreview: "",
                    usedChunking: false,
                    error: nil
                )
            }
            let success = await persist(chapters: rssChapters, episode: episode, context: context)
            debug.succeeded = success
            if !success, let error {
                debug.generationError = error
            }
            return success
        }

        guard !segments.isEmpty else {
            error = "A transcript is required to generate chapters. Transcribe the episode first."
            errorEpisodeGUID = episode.guid
            debug.source = "transcript"
            debug.generationError = error
            return false
        }

        debug.source = "transcript"
        generationStatus = "Detecting topic boundaries…"

        let boundaries = await Task.detached { [self] in
            self.detectBoundaries(in: segments, duration: duration)
        }.value

        logger.info("Detected \(boundaries.count) chapter boundaries")
        debug.boundaryCount = boundaries.count
        debug.boundariesDescription = boundaries
            .map { ChapterTitleGenerator.formatTime($0) }
            .joined(separator: ", ")

        let drafts: [ChapterTitleGenerator.SegmentDraft] = boundaries.enumerated().map { index, start in
            let end = index + 1 < boundaries.count ? boundaries[index + 1] : duration
            let chapterSegments = segments.filter { $0.startTime >= start && $0.startTime < end }
            return .init(
                startTime: start,
                excerpt: ChapterTitleGenerator.excerpt(from: chapterSegments),
                transcript: ChapterTitleGenerator.fullTranscript(from: chapterSegments),
                summary: nil
            )
        }

        let summaryService = TranscriptSummaryService.shared
        generationStatus = "Summarizing chapters…"
        let beatResult = await summaryService.generateChapterBeats(
            drafts: drafts,
            episodeTitle: episode.title,
            episodeDuration: duration
        )

        var result: [Chapter] = []
        for (index, start) in boundaries.enumerated() {
            let end = index + 1 < boundaries.count ? boundaries[index + 1] : duration
            let draft = drafts[index]
            let beat = index < beatResult.beats.count ? beatResult.beats[index] : ChapterBeat(
                summary: "",
                title: ChapterTitleGenerator.lexicalTitle(from: draft.excerpt, startTime: start)
            )
            let summary = beat.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(Chapter(
                startTime: start,
                endTime: end,
                title: beat.title,
                summary: summary.isEmpty ? nil : summary
            ))
        }

        debug.beats = beatResult.entries.enumerated().map { index, entry in
            let end = index + 1 < boundaries.count ? boundaries[index + 1] : duration
            var updated = entry
            updated.endTime = end
            if index < result.count {
                updated.title = result[index].title
                updated.summary = result[index].summary ?? updated.summary
            }
            return updated
        }

        guard !result.isEmpty else {
            error = "No chapters could be generated."
            errorEpisodeGUID = episode.guid
            debug.generationError = error
            return false
        }

        generationStatus = "Building episode overview…"
        let overviewResult = await summaryService.generateOverview(
            chapters: result,
            episodeTitle: episode.title
        )
        debug.overview = overviewResult.text
        debug.overviewError = overviewResult.error

        let success = await persist(
            chapters: result,
            overview: overviewResult.text,
            episode: episode,
            context: context
        )
        debug.succeeded = success
        if !success, let error {
            debug.generationError = error
        }
        return success
    }

    // MARK: - Persistence

    private func persist(
        chapters: [Chapter],
        overview: String = "",
        episode: Episode,
        context: ModelContext
    ) async -> Bool {
        do {
            let guid = episode.guid
            let document = ChaptersDocument(
                chapters: chapters,
                overview: overview.isEmpty ? nil : overview,
                generatedAt: Date()
            )
            let filename = try await Task.detached { [self] in
                try self.saveChaptersToDisk(document: document, guid: guid)
            }.value

            episode.localChaptersPath = filename
            discardObsoleteSummaryArtifacts(for: episode)
            try? context.save()
            if loadedEpisodeGUID == guid {
                self.chapters = chapters
                self.overview = overview
            }
            logger.info("Chapters saved: \(filename) (\(chapters.count) chapters)")
            return true
        } catch {
            logger.error("Save failed: \(error.localizedDescription)")
            self.error = "Could not save chapters: \(error.localizedDescription)"
            errorEpisodeGUID = episode.guid
            return false
        }
    }

    // MARK: - Boundary Detection (NLEmbedding)

    nonisolated private func detectBoundaries(
        in segments: [TranscriptSegment],
        duration: TimeInterval
    ) -> [TimeInterval] {
        guard duration > 30 else { return [0] }

        let timeline = TranscriptTimeline(segments: segments)
        let (_, maxChapters) = recommendedChapterRange(duration: duration)

        // Coarse windows only detect *that* a topic shift exists. Exact placement
        // is refined later onto natural breaks (pauses / sentence edges).
        let windowDur: TimeInterval = 120
        let stride: TimeInterval = 60

        var windows: [(start: TimeInterval, text: String)] = []
        var t: TimeInterval = 0
        while t < duration {
            let wEnd = min(t + windowDur, duration)
            let text = timeline.text(from: t, to: wEnd)
            if !text.isEmpty { windows.append((start: t, text: text)) }
            t += stride
        }

        guard windows.count >= 3 else {
            return evenlySpacedBoundaries(duration: duration, count: min(3, maxChapters))
        }

        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        let similarities: [Double]
        if let embedding {
            let vectors = windows.map { embedding.vector(for: $0.text) }
            similarities = (0..<(windows.count - 1)).map { i -> Double in
                guard let v1 = vectors[i], let v2 = vectors[i + 1] else { return 1.0 }
                return cosineSimilarity(v1, v2)
            }
        } else {
            let wordSets = windows.map { significantWords(in: $0.text) }
            similarities = (0..<(wordSets.count - 1)).map { i in
                jaccardSimilarity(wordSets[i], wordSets[i + 1])
            }
        }

        let smoothed = smooth(similarities, windowSize: 3)

        // Local minima in the similarity curve = candidate topic shifts.
        var minima: [(index: Int, time: TimeInterval, value: Double)] = []
        for i in 0..<smoothed.count {
            let prev = i > 0 ? smoothed[i - 1] : Double.infinity
            let next = i < smoothed.count - 1 ? smoothed[i + 1] : Double.infinity
            guard smoothed[i] < prev, smoothed[i] < next else { continue }
            // Transition sits between window i and i+1 — use the midpoint, not the grid edge.
            let left = windows[i].start + windowDur / 2
            let right = windows[min(i + 1, windows.count - 1)].start + windowDur / 2
            minima.append((index: i, time: (left + right) / 2, value: smoothed[i]))
        }

        // Prominence: how far this valley drops below the lowest ridge toward
        // neighboring valleys. Stacked noise dips share a shallow basin and score low;
        // a real topic shift stands alone and scores high.
        var candidates: [(time: TimeInterval, prominence: Double)] = []
        for (idx, minimum) in minima.enumerated() {
            let leftRidge = ridgeHeight(
                from: minimum.index,
                through: idx > 0 ? minima[idx - 1].index : 0,
                in: smoothed,
                direction: -1
            )
            let rightRidge = ridgeHeight(
                from: minimum.index,
                through: idx + 1 < minima.count ? minima[idx + 1].index : smoothed.count - 1,
                in: smoothed,
                direction: 1
            )
            let prominence = min(leftRidge, rightRidge) - minimum.value
            guard prominence > 0 else { continue }
            candidates.append((time: minimum.time, prominence: prominence))
        }

        candidates.sort { $0.prominence > $1.prominence }

        // Non-maximum suppression: stronger boundaries claim a neighborhood so
        // weaker neighbors in the same stretch can't stack. Radius scales with
        // expected chapter spacing — not a fixed "min chapter length."
        let competitionRadius = max(90, duration / Double(maxChapters * 2))
        var selected: [TimeInterval] = [0]

        for candidate in candidates {
            guard candidate.time > competitionRadius * 0.5 else { continue }
            let dominated = selected.contains { abs($0 - candidate.time) < competitionRadius }
            if !dominated { selected.append(candidate.time) }
            if selected.count >= maxChapters { break }
        }

        selected.sort()

        // One pass over the transcript for natural breaks; shared embedding cache
        // across chapters so overlapping context windows aren't recomputed.
        let breaks = timeline.naturalBreaks()
        var vectorCache: [TranscriptTimeline.RangeKey: [Double]] = [:]
        var refined: [TimeInterval] = [0]
        let minSeparation = competitionRadius * 0.5
        for coarse in selected where coarse > 0 {
            let time = refineBoundaryTime(
                around: coarse,
                timeline: timeline,
                breaks: breaks,
                embedding: embedding,
                vectorCache: &vectorCache,
                searchRadius: stride * 2
            )
            guard time > minSeparation else { continue }
            guard !refined.contains(where: { abs($0 - time) < minSeparation }) else { continue }
            refined.append(time)
        }

        return limitTailBoundaries(refined, duration: duration)
    }

    // MARK: - Helpers

    nonisolated private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = zip(a, b).map(*).reduce(0, +)
        let normA = sqrt(a.map { $0 * $0 }.reduce(0, +))
        let normB = sqrt(b.map { $0 * $0 }.reduce(0, +))
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA * normB)
    }

    nonisolated private func smooth(_ values: [Double], windowSize: Int) -> [Double] {
        guard values.count > windowSize else { return values }
        return values.indices.map { i in
            let lo = max(0, i - windowSize / 2)
            let hi = min(values.count, i + windowSize / 2 + 1)
            let slice = values[lo..<hi]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    nonisolated private func significantWords(in text: String) -> Set<String> {
        Set(ChapterTitleGenerator.topKeywords(in: text, limit: 32))
    }

    nonisolated private func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        let union = Double(a.union(b).count)
        return union > 0 ? Double(a.intersection(b).count) / union : 0
    }

    nonisolated private func evenlySpacedBoundaries(duration: TimeInterval, count: Int) -> [TimeInterval] {
        guard count > 0 else { return [0] }
        let interval = duration / Double(count)
        return (0..<count).map { TimeInterval($0) * interval }
    }

    /// ~1 chapter per 9 minutes, capped for very long episodes.
    nonisolated private func recommendedChapterRange(duration: TimeInterval) -> (Int, Int) {
        let minChapters = duration < 600 ? 2 : 3
        let scaled = Int(round(duration / 540))
        let maxChapters = min(16, max(minChapters + 1, scaled))
        return (minChapters, maxChapters)
    }

    /// Pick the segment start near `coarseTime` that best splits before/after topic.
    /// Considers the closest natural breaks and scores all of them with embeddings
    /// (lexical score is only a fallback when embeddings are unavailable).
    nonisolated private func refineBoundaryTime(
        around coarseTime: TimeInterval,
        timeline: TranscriptTimeline,
        breaks: [TranscriptTimeline.NaturalBreak],
        embedding: NLEmbedding?,
        vectorCache: inout [TranscriptTimeline.RangeKey: [Double]],
        searchRadius: TimeInterval,
        contextDur: TimeInterval = 90,
        /// Closest breaks to the coarse hit that we fully score.
        candidatePool: Int = 24
    ) -> TimeInterval {
        let lo = max(0, coarseTime - searchRadius)
        let hi = coarseTime + searchRadius

        var nearby = timeline.breaks(breaks, from: lo, to: hi)
        if nearby.isEmpty {
            nearby = timeline.fallbackBreaks(from: lo, to: hi)
        }
        guard !nearby.isEmpty else { return coarseTime }

        // Stay near the detected topic shift — don't let a long pause elsewhere
        // in the window steal the shortlist from a better local break.
        nearby.sort { abs($0.time - coarseTime) < abs($1.time - coarseTime) }
        let shortlist = Array(nearby.prefix(candidatePool))

        struct ScoredBreak {
            let candidate: TranscriptTimeline.NaturalBreak
            let beforeRange: TranscriptTimeline.RangeKey
            let afterRange: TranscriptTimeline.RangeKey
        }

        let candidates: [ScoredBreak] = shortlist.compactMap { candidate in
            let beforeRange = timeline.range(from: max(0, candidate.time - contextDur), to: candidate.time)
            let afterRange = timeline.range(from: candidate.time, to: candidate.time + contextDur)
            let before = timeline.text(beforeRange)
            let after = timeline.text(afterRange)
            guard before.count > 20, after.count > 20 else { return nil }
            return ScoredBreak(
                candidate: candidate,
                beforeRange: beforeRange,
                afterRange: afterRange
            )
        }
        guard !candidates.isEmpty else { return coarseTime }

        var bestTime = candidates[0].candidate.time
        var bestScore = -Double.infinity

        for item in candidates {
            let candidate = item.candidate
            let similarity: Double
            if let embedding,
               let v1 = timeline.vector(for: item.beforeRange, embedding: embedding, cache: &vectorCache),
               let v2 = timeline.vector(for: item.afterRange, embedding: embedding, cache: &vectorCache) {
                similarity = cosineSimilarity(v1, v2)
            } else {
                let before = timeline.text(item.beforeRange)
                let after = timeline.text(item.afterRange)
                similarity = jaccardSimilarity(significantWords(in: before), significantWords(in: after))
            }

            let score = breakScore(
                similarity: similarity,
                gap: candidate.gap,
                afterSentence: candidate.afterSentence,
                time: candidate.time,
                coarseTime: coarseTime,
                searchRadius: searchRadius
            )
            if score > bestScore {
                bestScore = score
                bestTime = candidate.time
            }
        }

        return bestTime
    }

    nonisolated private func breakScore(
        similarity: Double,
        gap: TimeInterval,
        afterSentence: Bool,
        time: TimeInterval,
        coarseTime: TimeInterval,
        searchRadius: TimeInterval
    ) -> Double {
        // Topic shift dominates; pause/sentence are light tiebreakers only.
        let pauseBonus = min(gap / 4.0, 0.08)
        let sentenceBonus = afterSentence ? 0.04 : 0
        let proximityPenalty = abs(time - coarseTime) / (searchRadius * 3)
        return (1 - similarity) + pauseBonus + sentenceBonus - proximityPenalty
    }

    /// Highest similarity between a valley and the next/previous valley (or edge).
    /// That ridge is the baseline for prominence — shared basins score low.
    nonisolated private func ridgeHeight(
        from start: Int,
        through end: Int,
        in values: [Double],
        direction: Int
    ) -> Double {
        guard !values.isEmpty else { return 0 }
        var i = start
        var peak = values[start]
        let step = direction >= 0 ? 1 : -1
        while i != end {
            i += step
            guard i >= 0, i < values.count else { break }
            peak = max(peak, values[i])
        }
        return peak
    }

    /// Avoid many micro-chapters in the closing minutes (credits, name roll calls, plugs).
    nonisolated private func limitTailBoundaries(
        _ boundaries: [TimeInterval],
        duration: TimeInterval,
        maxInTail: Int = 1
    ) -> [TimeInterval] {
        guard duration > 900 else { return boundaries }
        let tailStart = duration - min(720, duration * 0.15)
        var tailCount = 0
        return boundaries.sorted().filter { time in
            guard time >= tailStart else { return true }
            guard tailCount < maxInTail else { return false }
            tailCount += 1
            return true
        }
    }

    // MARK: - Disk Persistence

    nonisolated private func chaptersDirectory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private func saveChaptersToDisk(document: ChaptersDocument, guid: String) throws -> String {
        let data = try JSONEncoder().encode(document)
        let filename = sanitizedFilename(for: guid) + ".json"
        let url = try chaptersDirectory().appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return filename
    }

    nonisolated private func sanitizedFilename(for guid: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        return String(
            guid.unicodeScalars
                .filter { allowed.contains($0) }
                .map(Character.init)
                .prefix(128)
        )
    }
}
