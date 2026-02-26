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

    /// Boundary detection uses NLEmbedding (iOS 13+), so generation is always available.
    /// Chapter titles use Apple Intelligence when available, falling back to "Chapter N".
    nonisolated static var isSupported: Bool { true }

    nonisolated static var titlesSupported: Bool {
        if #available(iOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
    }

    // MARK: - Public API

    /// Load persisted chapters for episode from disk. Synchronous / O(1).
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

    /// Generate chapters from the episode's transcript.
    /// Step 1: NLEmbedding similarity → topic boundaries (no Apple Intelligence needed).
    /// Step 2: LLM per chapter → titles (falls back to "Chapter N" without Apple Intelligence).
    @discardableResult
    func generate(episode: Episode, context: ModelContext) async -> Bool {
        guard !isGenerating else { return false }

        // Clear any previously generated chapters so regeneration works cleanly
        if let oldURL = episode.localChaptersURL {
            try? FileManager.default.removeItem(at: oldURL)
        }
        episode.localChaptersPath = nil
        chapters = []

        let transcriptService = TranscriptService.shared
        await transcriptService.load(for: episode)
        let segments = transcriptService.segments
        guard !segments.isEmpty else {
            error = "A transcript is required to generate chapters. Transcribe the episode first."
            return false
        }

        isGenerating = true
        error = nil
        generationStatus = "Detecting topic boundaries…"
        generatingEpisodeGUID = episode.guid

        defer {
            isGenerating = false
            generationStatus = ""
            generatingEpisodeGUID = nil
        }

        let duration = episode.duration ?? segments.last?.endTime ?? 0

        // Step 1: Boundary detection (CPU-bound NLEmbedding work, off main thread)
        let boundaries = await Task.detached { [self] in
            self.detectBoundaries(in: segments, duration: duration)
        }.value

        logger.info("Detected \(boundaries.count) chapter boundaries")

        // Step 2: Title each chapter
        var result: [Chapter] = []
        let canTitle = ChapterService.titlesSupported
        let total = boundaries.count

        for (index, start) in boundaries.enumerated() {
            let end = index + 1 < boundaries.count ? boundaries[index + 1] : duration

            if canTitle {
                generationStatus = "Writing titles (\(index + 1)/\(total))…"
            }

            let chapterText = segments
                .filter { $0.startTime >= start && $0.startTime < end }
                .map(\.text)
                .joined(separator: " ")

            let title: String
            if canTitle, #available(iOS 26, *), !chapterText.isEmpty {
                title = (try? await generateTitle(
                    for: String(chapterText.prefix(700)),
                    episodeTitle: episode.title,
                    chapterIndex: index + 1
                )) ?? "Chapter \(index + 1)"
            } else {
                title = "Chapter \(index + 1)"
            }

            result.append(Chapter(startTime: start, endTime: end, title: title))
        }

        guard !result.isEmpty else {
            error = "No chapters could be generated."
            return false
        }

        do {
            let guid = episode.guid
            let filename = try await Task.detached { [self] in
                try self.saveChaptersToDisk(chapters: result, guid: guid)
            }.value

            episode.localChaptersPath = filename
            try? context.save()
            chapters = result
            logger.info("Chapters saved: \(filename) (\(result.count) chapters)")
            return true
        } catch {
            logger.error("Save failed: \(error.localizedDescription)")
            self.error = "Could not save chapters: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Boundary Detection (NLEmbedding)

    /// Detects topic-shift boundaries in the transcript using cosine similarity of sentence
    /// embeddings across overlapping 2-minute windows with a 1-minute stride.
    /// Falls back to lexical (Jaccard) similarity if NLEmbedding is unavailable.
    nonisolated private func detectBoundaries(
        in segments: [TranscriptSegment],
        duration: TimeInterval
    ) -> [TimeInterval] {
        guard duration > 30 else { return [0] }

        let (minChapters, maxChapters) = recommendedChapterRange(duration: duration)

        // Build overlapping windows: 2-min window, 1-min stride
        let windowDur: TimeInterval = 120
        let stride: TimeInterval   = 60

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
            return evenlySpacedBoundaries(duration: duration, count: min(minChapters, windows.count))
        }

        // Compute similarity between each pair of adjacent windows
        let similarities: [Double]
        if let embedding = NLEmbedding.sentenceEmbedding(for: .english) {
            let vectors = windows.map { embedding.vector(for: $0.text) }
            similarities = (0..<(windows.count - 1)).map { i -> Double in
                guard let v1 = vectors[i], let v2 = vectors[i + 1] else { return 1.0 }
                return cosineSimilarity(v1, v2)
            }
        } else {
            // Lexical fallback: Jaccard overlap on significant words
            let wordSets = windows.map { significantWords(in: $0.text) }
            similarities = (0..<(wordSets.count - 1)).map { i in
                jaccardSimilarity(wordSets[i], wordSets[i + 1])
            }
        }

        // Smooth to reduce noise from individual sentences
        let smoothed = smooth(similarities, windowSize: 3)
        let mean = smoothed.reduce(0, +) / Double(smoothed.count)

        // Find local minima — each represents a vocabulary shift (likely topic change)
        var candidates: [(time: TimeInterval, depth: Double)] = []
        for i in 0..<smoothed.count {
            let prev = i > 0 ? smoothed[i - 1] : Double.infinity
            let next = i < smoothed.count - 1 ? smoothed[i + 1] : Double.infinity
            guard smoothed[i] < prev, smoothed[i] < next else { continue }
            // The boundary is at the start of the window *after* the dip
            let boundaryTime = windows[min(i + 1, windows.count - 1)].start
            candidates.append((time: boundaryTime, depth: mean - smoothed[i]))
        }

        // Sort by significance (deepest dip = most distinct topic change)
        candidates.sort { $0.depth > $1.depth }

        // Pick top boundaries respecting a minimum gap
        let minGap: TimeInterval = max(60, duration / Double(maxChapters + 1))
        var selected: [TimeInterval] = [0]

        for candidate in candidates {
            guard candidate.time > minGap else { continue }  // too close to start
            let tooClose = selected.contains { abs($0 - candidate.time) < minGap }
            if !tooClose { selected.append(candidate.time) }
            if selected.count >= maxChapters { break }
        }

        selected.sort()

        // If still below minimum, bisect the largest gaps to pad up
        if selected.count < minChapters {
            var gaps = zip(selected, selected.dropFirst())
                .map { (start: $0.0, end: $0.1) }
            if let last = selected.last { gaps.append((start: last, end: duration)) }
            gaps.sort { ($0.end - $0.start) > ($1.end - $1.start) }

            for gap in gaps {
                guard selected.count < minChapters else { break }
                let mid = (gap.start + gap.end) / 2
                if !selected.contains(where: { abs($0 - mid) < minGap }) {
                    selected.append(mid)
                }
            }
            selected.sort()
        }

        return selected
    }

    // MARK: - Title Generation (Apple Intelligence)

    @available(iOS 26, *)
    nonisolated private func generateTitle(
        for text: String,
        episodeTitle: String,
        chapterIndex: Int
    ) async throws -> String {
        let prompt = """
        Write a chapter title for this podcast segment. \
        Reply with ONLY the title — 4 to 7 words, no quotes, no trailing punctuation.
        Be specific to what is actually discussed; avoid generic labels like \
        "Introduction", "Discussion", or "Conclusion".

        Podcast: "\(episodeTitle)"
        Transcript excerpt: \(text)
        """
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt, generating: ChapterTitle.self)
        let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Chapter \(chapterIndex)" : title
    }

    // MARK: - Helpers

    nonisolated private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot   = zip(a, b).map(*).reduce(0, +)
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
        let stopWords: Set<String> = [
            "the","a","an","and","or","but","in","on","at","to","for","of","with",
            "is","it","that","this","was","are","be","been","have","has","had",
            "do","did","will","would","could","should","may","i","you","we","they",
            "he","she","so","my","your","like","just","know","think","yeah","um","uh",
            "its","we're","i'm","you're","they're","don't","can't","won't","isn't"
        ]
        return Set(
            text.lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { $0.count > 3 && !stopWords.contains($0) }
        )
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

    nonisolated private func recommendedChapterRange(duration: TimeInterval) -> (Int, Int) {
        switch duration {
        case ..<600:    return (2, 4)    // <10 min
        case ..<1800:   return (3, 6)    // 10–30 min
        case ..<3600:   return (5, 9)    // 30–60 min
        default:        return (7, 12)   // 60+ min
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

// MARK: - @Generable type for chapter title

@available(iOS 26, *)
@Generable
private struct ChapterTitle {
    @Guide(description: "A 4–7 word chapter title specific to what is discussed in this segment. No generic labels like 'Introduction' or 'Discussion'.")
    var title: String
}
