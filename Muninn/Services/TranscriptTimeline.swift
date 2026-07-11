import Foundation
import NaturalLanguage

/// Random-access helpers over a time-sorted transcript.
/// Avoids repeated full-array scans when scoring chapter boundaries.
struct TranscriptTimeline: Sendable {
    struct RangeKey: Hashable, Sendable {
        let start: Int
        let end: Int

        var isEmpty: Bool { start >= end }
    }

    struct NaturalBreak: Sendable {
        let index: Int
        let time: TimeInterval
        let gap: TimeInterval
        let afterSentence: Bool
    }

    let segments: [TranscriptSegment]

    init(segments: [TranscriptSegment]) {
        self.segments = segments
    }

    /// First index with `startTime >= time`.
    func firstIndex(atOrAfter time: TimeInterval) -> Int {
        var lo = 0
        var hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].startTime < time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// Half-open segment index range covering `[start, end)`.
    func range(from start: TimeInterval, to end: TimeInterval) -> RangeKey {
        guard end > start else { return RangeKey(start: 0, end: 0) }
        let i = firstIndex(atOrAfter: start)
        let j = firstIndex(atOrAfter: end)
        return RangeKey(start: i, end: max(i, j))
    }

    func text(_ range: RangeKey) -> String {
        guard !range.isEmpty, range.start < segments.count else { return "" }
        let end = min(range.end, segments.count)
        guard range.start < end else { return "" }
        return segments[range.start..<end].map(\.text).joined(separator: " ")
    }

    func text(from start: TimeInterval, to end: TimeInterval) -> String {
        text(range(from: start, to: end))
    }

    /// Transcript for `[start, end)` excluding segments that extend past `end`.
    func heardText(from start: TimeInterval, to end: TimeInterval) -> String {
        guard end > start else { return "" }
        let key = range(from: start, to: end)
        guard !key.isEmpty, key.start < segments.count else { return "" }

        let upper = min(key.end, segments.count)
        var parts: [String] = []
        parts.reserveCapacity(upper - key.start)

        for index in key.start..<upper {
            let segment = segments[index]
            if segment.endTime <= end {
                parts.append(segment.text)
            }
        }

        return parts.joined(separator: " ")
    }

    /// All pause / sentence-edge breaks in the transcript (single O(n) pass).
    func naturalBreaks(minGap: TimeInterval = 0.35) -> [NaturalBreak] {
        guard segments.count > 1 else { return [] }
        var breaks: [NaturalBreak] = []
        breaks.reserveCapacity(segments.count / 8)
        for i in 1..<segments.count {
            let gap = segments[i].startTime - segments[i - 1].endTime
            let afterSentence = Self.endsSentence(segments[i - 1].text)
            guard gap >= minGap || afterSentence else { continue }
            breaks.append(NaturalBreak(
                index: i,
                time: segments[i].startTime,
                gap: max(0, gap),
                afterSentence: afterSentence
            ))
        }
        return breaks
    }

    /// Breaks whose times fall in `[lo, hi]`. `breaks` must be time-sorted.
    func breaks(_ breaks: [NaturalBreak], from lo: TimeInterval, to hi: TimeInterval) -> [NaturalBreak] {
        guard !breaks.isEmpty, hi >= lo else { return [] }
        var left = 0
        var right = breaks.count
        while left < right {
            let mid = (left + right) / 2
            if breaks[mid].time < lo {
                left = mid + 1
            } else {
                right = mid
            }
        }
        var result: [NaturalBreak] = []
        var i = left
        while i < breaks.count, breaks[i].time <= hi {
            result.append(breaks[i])
            i += 1
        }
        return result
    }

    /// Sparse sample when no pauses/sentence edges exist in the window.
    func fallbackBreaks(from lo: TimeInterval, to hi: TimeInterval) -> [NaturalBreak] {
        let start = max(1, firstIndex(atOrAfter: lo))
        let end = firstIndex(atOrAfter: hi)
        guard start < end else { return [] }

        var result: [NaturalBreak] = []
        var i = start
        while i < end {
            let gap = segments[i].startTime - segments[i - 1].endTime
            result.append(NaturalBreak(
                index: i,
                time: segments[i].startTime,
                gap: max(0, gap),
                afterSentence: Self.endsSentence(segments[i - 1].text)
            ))
            i += 4
        }
        return result
    }

    /// Cached embedding for a segment index range.
    func vector(
        for range: RangeKey,
        embedding: NLEmbedding,
        cache: inout [RangeKey: [Double]]
    ) -> [Double]? {
        guard !range.isEmpty else { return nil }
        if let cached = cache[range] { return cached }
        let body = text(range)
        guard body.count > 20, let vector = embedding.vector(for: body) else { return nil }
        cache[range] = vector
        return vector
    }

    private static func endsSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        return ".?!…".contains(last)
    }
}
