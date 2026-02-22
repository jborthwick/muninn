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

### ✅ Auto-Transcription After Download
- **Status**: Complete
- **Description**: Episodes auto-transcribe after download when "Auto-Transcribe" is enabled in Settings → Transcription.
- **How it works**:
  - `AutoTranscriptionQueue` holds a FIFO queue; one episode transcribes at a time
  - `DownloadObserver` triggers transcription after download if auto-transcribe is on, or if user explicitly tapped a transcribe action before the download finished (`pendingTranscribeOnDownload`)
  - `Episode.transcriptionProgress: Double?` tracks per-episode progress (nil = idle, 0–1 = in progress)
  - Deleting an episode's download also deletes its transcript (stale timestamps from ad re-insertion)
- **UI**:
  - List rows show download state only (no transcription indicator)
  - `EpisodeDetailView` has a dedicated "Transcript" section showing: transcribing progress bar → "Transcribed" label → queue position → "Not yet transcribed" → "Download to generate transcription"
  - Settings → Transcription section has the Auto-Transcribe toggle (disabled with explanation on unsupported devices)
- **Files**:
  - `AutoTranscriptionQueue.swift` (new)
  - `LocalTranscriptionService.swift`, `DownloadObserver.swift`, `DownloadManager.swift`, `MuninnApp.swift`
  - `Episode.swift` (`transcriptionProgress`), `AppSettings.swift` (`autoTranscribeEnabled`)
  - `EpisodeDetailView.swift`, `SettingsView.swift`

### ✅ Navigation Transition Glitch on Podcast Show Page
- **Status**: Complete
- **Description**: Slide-in animation to podcast detail page was stuttering and the header was "popping in".
- **Root causes fixed**:
  1. `htmlStripped` (NSAttributedString/WebKit) was called synchronously in `PodcastHeaderView.body` — replaced with `htmlTagsStripped` (fast regex)
  2. `CachedAsyncImage` state update inherited the active navigation transaction — wrapped with `withTransaction(.init(animation: .easeIn(duration: 0.15)))` to decouple
- **Files**: `String+HTML.swift`, `PodcastDetailView.swift`, `ImageCache.swift`
