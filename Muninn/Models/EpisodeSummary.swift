import Foundation

/// On-device episode intelligence generated from the transcript.
struct EpisodeSummary: Codable, Equatable {
    var overview: String
    var beats: [SummaryBeat]
    var generatedAt: Date
}

struct SummaryBeat: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var startTime: TimeInterval
    var endTime: TimeInterval
    var summary: String
}
