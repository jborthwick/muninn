import Foundation

/// A single time-coded segment from a podcast transcript.
/// In-memory only — not persisted to SwiftData.
struct TranscriptSegment: Identifiable, Equatable {
    let id: UUID = UUID()
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speaker: String?  // optional voice/speaker label (from VTT cue headers)
}
