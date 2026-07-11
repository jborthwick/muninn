import Foundation

struct Chapter: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var startTime: TimeInterval
    var endTime: TimeInterval   // next chapter's startTime, or episode duration
    var title: String
    /// On-device chapter summary; nil for show-note chapters or failed summarization.
    var summary: String? = nil
}

/// On-disk chapters file. Overview lives here so playback + intelligence share one artifact.
struct ChaptersDocument: Codable, Equatable {
    var chapters: [Chapter]
    var overview: String?
    var generatedAt: Date?
}
