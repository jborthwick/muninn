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
    private(set) var isGenerating = false
    private(set) var generationStatus: String = ""
    private(set) var error: String?
    private(set) var generatingEpisodeGUID: String?

    // MARK: - Availability

    nonisolated static var isSupported: Bool { true }

    nonisolated static var titlesSupported: Bool {
        if #available(iOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
    }

    // MARK: - Public API

    func load(for episode: Episode) {
        guard let url = episode.localChaptersURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            chapters = []
            return
        }
        struct Wrapper: Decodable { let chapters: [Chapter] }
        chapters = (try? JSONDecoder().decode(Wrapper.self, from: data))?.chapters ?? []
        error = nil
    }

    func clear() {
        chapters = []
        error = nil
        generationStatus = ""
    }

    /// Generate chapters from show notes (fast path) or transcript (boundaries + titles).
    @discardableResult
    func generate(episode: Episode, context: ModelContext) async -> Bool {
        guard !isGenerating else { return false }

        if let oldURL = episode.localChaptersURL {
            try? FileManager.default.removeItem(at: oldURL)
        }
        episode.localChaptersPath = nil
        chapters = []

        isGenerating = true
        error = nil
        generatingEpisodeGUID = episode.guid

        defer {
            isGenerating = false
            generationStatus = ""
            generatingEpisodeGUID = nil
        }

        let transcriptService = TranscriptService.shared
        await transcriptService.load(for: episode)
        let segments = transcriptService.segments
        let duration = episode.duration ?? segments.last?.endTime ?? 0

        // Fast path: chapters already in episode show notes.
        if let rssChapters = ChapterShowNotesParser.chapters(from: episode.episodeDescription, duration: duration) {
            generationStatus = "Using show note chapters…"
            return await persist(chapters: rssChapters, episode: episode, context: context)
        }

        guard !segments.isEmpty else {
            error = "A transcript is required to generate chapters. Transcribe the episode first."
            return false
        }

        generationStatus = "Detecting topic boundaries…"

        let boundaries = await Task.detached { [self] in
            self.detectBoundaries(in: segments, duration: duration)
        }.value

        logger.info("Detected \(boundaries.count) chapter boundaries")

        let drafts: [ChapterTitleGenerator.SegmentDraft] = boundaries.enumerated().map { index, start in
            let end = index + 1 < boundaries.count ? boundaries[index + 1] : duration
            let chapterSegments = segments.filter { $0.startTime >= start && $0.startTime < end }
            return .init(
                startTime: start,
                excerpt: ChapterTitleGenerator.excerpt(from: chapterSegments)
            )
        }

        generationStatus = "Writing chapter titles…"
        let synopsis = ChapterShowNotesParser.synopsis(from: episode.episodeDescription)
        let titles: [String]
        if #available(iOS 26, *) {
            titles = await ChapterTitleGenerator.titles(
                for: drafts,
                episodeTitle: episode.title,
                synopsis: synopsis
            )
        } else {
            titles = drafts.map { ChapterTitleGenerator.lexicalTitle(from: $0.excerpt, startTime: $0.startTime) }
        }

        var result: [Chapter] = []
        for (index, start) in boundaries.enumerated() {
            let end = index + 1 < boundaries.count ? boundaries[index + 1] : duration
            let title = index < titles.count ? titles[index] : ChapterTitleGenerator.lexicalTitle(
                from: drafts[index].excerpt,
                startTime: start
            )
            result.append(Chapter(startTime: start, endTime: end, title: title))
        }

        guard !result.isEmpty else {
            error = "No chapters could be generated."
            return false
        }

        return await persist(chapters: result, episode: episode, context: context)
    }

    // MARK: - Persistence

    private func persist(chapters: [Chapter], episode: Episode, context: ModelContext) async -> Bool {
        do {
            let guid = episode.guid
            let filename = try await Task.detached { [self] in
                try self.saveChaptersToDisk(chapters: chapters, guid: guid)
            }.value

            episode.localChaptersPath = filename
            try? context.save()
            self.chapters = chapters
            logger.info("Chapters saved: \(filename) (\(chapters.count) chapters)")
            return true
        } catch {
            logger.error("Save failed: \(error.localizedDescription)")
            self.error = "Could not save chapters: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Boundary Detection (NLEmbedding)

    nonisolated private func detectBoundaries(
        in segments: [TranscriptSegment],
        duration: TimeInterval
    ) -> [TimeInterval] {
        guard duration > 30 else { return [0] }

        let (_, maxChapters) = recommendedChapterRange(duration: duration)

        let windowDur: TimeInterval = 120
        let stride: TimeInterval = 60

        var windows: [(start: TimeInterval, text: String)] = []
        var t: TimeInterval = 0
        while t < duration {
            let wEnd = min(t + windowDur, duration)
            let text = segments
                .filter { $0.startTime >= t && $0.startTime < wEnd }
                .map(\.text)
                .joined(separator: " ")
            if !text.isEmpty { windows.append((start: t, text: text)) }
            t += stride
        }

        guard windows.count >= 3 else {
            return evenlySpacedBoundaries(duration: duration, count: min(3, maxChapters))
        }

        let similarities: [Double]
        if let embedding = NLEmbedding.sentenceEmbedding(for: .english) {
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
        let mean = smoothed.reduce(0, +) / Double(smoothed.count)

        var candidates: [(time: TimeInterval, depth: Double)] = []
        for i in 0..<smoothed.count {
            let prev = i > 0 ? smoothed[i - 1] : Double.infinity
            let next = i < smoothed.count - 1 ? smoothed[i + 1] : Double.infinity
            guard smoothed[i] < prev, smoothed[i] < next else { continue }
            let boundaryTime = windows[min(i + 1, windows.count - 1)].start
            candidates.append((time: boundaryTime, depth: mean - smoothed[i]))
        }

        candidates.sort { $0.depth > $1.depth }

        // Apple guidance: ≥2 min between chapters, ~6 per hour max.
        let minGap: TimeInterval = max(120, duration / Double(maxChapters + 1))
        var selected: [TimeInterval] = [0]

        for candidate in candidates {
            guard candidate.time > minGap else { continue }
            let tooClose = selected.contains { abs($0 - candidate.time) < minGap }
            if !tooClose { selected.append(candidate.time) }
            if selected.count >= maxChapters { break }
        }

        selected.sort()
        return selected
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

    /// Tighter chapter density aligned with Apple Podcasts creator guidance (~6/hour).
    nonisolated private func recommendedChapterRange(duration: TimeInterval) -> (Int, Int) {
        switch duration {
        case ..<600:    return (2, 3)
        case ..<1800:   return (2, 4)
        case ..<3600:   return (3, 6)
        default:        return (4, 8)
        }
    }

    // MARK: - Disk Persistence

    nonisolated private func chaptersDirectory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private func saveChaptersToDisk(chapters: [Chapter], guid: String) throws -> String {
        struct Wrapper: Encodable { let chapters: [Chapter] }
        let data = try JSONEncoder().encode(Wrapper(chapters: chapters))
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
