import Foundation

/// Per-chapter capture from the most recent chapter generation run.
struct ChapterBeatDebugEntry: Equatable, Identifiable {
    var id: Int { index }
    var index: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var title: String
    var summary: String
    /// show_notes, roll_call, foundation_model, lexical_fallback, persisted
    var source: String
    var flaggedRollCall: Bool
    var transcriptCharacters: Int
    var excerptPreview: String
    var usedChunking: Bool
    var error: String?
}

/// Captured inputs/outputs from the most recent chapter generation run.
struct ChapterGenerationDebugInfo: Equatable {
    var generatedAt = Date()
    var episodeTitle = ""
    var episodeGUID = ""
    var episodeDuration: TimeInterval = 0
    /// show_notes, transcript, persisted
    var source = ""
    var segmentCount = 0
    var boundaryCount = 0
    var boundariesDescription = ""
    var foundationModelAvailable = false
    var beats: [ChapterBeatDebugEntry] = []
    var overview = ""
    var overviewError: String?
    var summarySaveError: String?
    var generationError: String?
    var succeeded = false
}
