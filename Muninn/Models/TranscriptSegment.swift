import Foundation

/// A single time-coded span from a podcast transcript.
/// May represent a phrase (RSS VTT cue) or a single word when word-level timing is available.
/// In-memory only — not persisted to SwiftData.
struct TranscriptSegment: Identifiable, Equatable {
    let id: UUID = UUID()
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speaker: String?  // optional voice/speaker label (from VTT cue headers)
}

extension Array where Element == TranscriptSegment {
    /// Binary-search the active segment at `time`. Segments must be sorted by `startTime`.
    func segment(at time: TimeInterval) -> TranscriptSegment? {
        guard !isEmpty else { return nil }

        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].startTime <= time {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        guard lo > 0 else {
            return time >= self[0].startTime ? self[0] : nil
        }

        let candidate = self[lo - 1]
        if time < candidate.endTime { return candidate }
        if lo < count, time < self[lo].startTime { return candidate }
        return time >= candidate.startTime ? candidate : nil
    }
}
