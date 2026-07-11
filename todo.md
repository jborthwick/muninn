# Muninn TODO List

## Bugs to Investigate

### 🔍 PodcastLookupService Called Unexpectedly
- **Status**: Open
- **Severity**: Medium
- **Description**:
  - `PodcastLookupService` is being called automatically with search terms ("naddpod", "exclusives", "patreon") even when user is not attempting to add a podcast
  - User is not performing any search action, yet the console shows podcast lookup results
  - Searches are failing to find matches (all negative/zero scores)
- **Possible Causes**:
  - Background refresh process triggering lookups
  - Debug view or feature calling PodcastLookupService
  - Related to similar podcast recommendations
  - Leftover from previous feature
- **Next Steps**:
  - Add stack traces to PodcastLookupService calls
  - Check what's triggering the lookups
  - Review background tasks and refresh logic

---

## Recently Completed

### ✅ Background Episode Processing
- **Status**: Complete
- **Description**: Transcription and chapter generation can resume after suspend, run via `BGProcessingTask`, and continue in the background on iOS 26+ for user-initiated downloads/transcribe actions via `BGContinuedProcessingTask`.
- **How it works**:
  - `PendingWorkStore` persists queued transcription/chapter GUIDs across relaunches
  - `EpisodeProcessingBackgroundManager` resumes interrupted work and schedules deferred processing
  - `EpisodeContinuedProcessing` drives manual download → transcribe → chapter pipelines with system progress UI on iOS 26+
- **Files**:
  - `EpisodeProcessingBackgroundManager.swift`, `EpisodeContinuedProcessing.swift`, `PendingWorkStore.swift`
  - `AutoTranscriptionQueue.swift`, `AutoChapterQueue.swift`, `DownloadManager.swift`, `MuninnApp.swift`

### ✅ Auto-Transcription and Auto-Chapters
- **Status**: Complete
- **Description**: Episodes auto-transcribe after download when "Auto-Transcribe" is enabled; chapters and summaries auto-generate when "Auto-Generate Chapters" is enabled.
- **How it works**:
  - `AutoTranscriptionQueue` holds a FIFO queue; one episode transcribes at a time
  - `AutoChapterQueue` runs after transcription completes
  - `DownloadObserver` triggers transcription after download if auto-transcribe is on, or if user explicitly tapped transcribe before the download finished (`pendingTranscribeOnDownload`)
  - `Episode.transcriptionProgress: Double?` tracks per-episode progress (nil = idle, 0–1 = in progress)
  - Deleting an episode's download also deletes its transcript
- **UI**:
  - `EpisodeProcessingStatusView` shows transcription/chapter queue and progress on episode rows
  - `EpisodeDetailView` has a dedicated "Transcript" section with progress, retry, and queue state
  - Settings → Transcription has Auto-Transcribe and Auto-Generate Chapters toggles
- **Files**:
  - `AutoTranscriptionQueue.swift`, `AutoChapterQueue.swift`, `LocalTranscriptionService.swift`
  - `ChapterService.swift`, `TranscriptSummaryService.swift`, `EpisodeProcessingStatusView.swift`

### ✅ Navigation Transition Glitch on Podcast Show Page
- **Status**: Complete
- **Description**: Slide-in animation to podcast detail page was stuttering and the header was "popping in".
- **Root causes fixed**:
  1. `htmlStripped` (NSAttributedString/WebKit) was called synchronously in `PodcastHeaderView.body` — replaced with `htmlTagsStripped` (fast regex)
  2. `CachedAsyncImage` state update inherited the active navigation transaction — wrapped with `withTransaction(.init(animation: .easeIn(duration: 0.15)))` to decouple
- **Files**: `String+HTML.swift`, `PodcastDetailView.swift`, `ImageCache.swift`
