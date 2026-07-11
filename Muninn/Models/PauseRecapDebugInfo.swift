import Foundation

/// Captured inputs/outputs from the most recent pause-recap generation run.
struct PauseRecapDebugInfo: Equatable {
    var generatedAt = Date()

    var pausedAt: TimeInterval = 0
    var totalBeatCount = 0
    var completedBeatCount = 0
    var skippedEmptyBeatCount = 0
    var cappedBeatCount = 0

    var hasInProgressChapter = false
    var inProgressChapterTitle: String?
    var inProgressRange: String?
    var partialSummary: String?
    var partialExcerptPreview: String?

    var beatInput = ""
    var recapPrompt = ""
    var recapRawResponse: String?
    var recapFinalText = ""
    var recapError: String?

    var usedFoundationModel = false
    var usedDirectJoin = false
    var usedFallback = false
    var needsChapters = false
}
