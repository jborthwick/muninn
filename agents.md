# Muninn – Agent Guide

iOS podcast player app focused on transcripts and AI-assisted audio understanding. Built with SwiftUI + SwiftData. App display name is **Muninn**, Xcode target is **Muninn**, bundle ID is **com.personal.muninn**.

## Build & Run

```bash
# Regenerate Xcode project after editing project.yml
xcodegen generate

# Open in Xcode
open muninn.xcodeproj

# Build check from terminal (no Xcode required)
xcodebuild -scheme Muninn -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Build and run from Xcode. There is no separate test suite — verify features manually on device/simulator.

**Adding new source files:** Run `xcodegen generate` after adding files to `Muninn/` so they appear in the Xcode project. Or use `add_file_to_xcode.py` for targeted additions.

## Architecture

- **SwiftUI** — all UI
- **SwiftData** — persistence (models in `Muninn/Models/`)
- **AVFoundation** — audio playback via `AudioPlayerManager` singleton
- **FeedKit** (SPM) — RSS parsing in `FeedService`
- **iCloud Drive** — sync via JSON file, not CloudKit (`SyncService`)

## Project Structure

```
Muninn/
├── Models/           # SwiftData: Podcast, Episode, Folder, QueueItem, AppSettings, ListeningStats
├── Services/         # Business logic (see below)
├── Views/
│   ├── Library/      # LibraryView, AddPodcastView, AllEpisodesView, PodcastRowView
│   ├── Player/       # NowPlayingView, MiniPlayerView
│   ├── Podcast/      # PodcastDetailView, EpisodeRowView
│   ├── Episode/      # EpisodeDetailView
│   ├── Folders/      # FolderDetailView, EditFolderView, FolderPickerView
│   ├── Downloads/    # DownloadsView
│   ├── Starred/      # StarredView
│   ├── Queue/        # QueueView
│   ├── Stats/        # StatsView
│   ├── Settings/     # SettingsView, ExportImportView, CrashLogsView
│   └── Shared/       # EpisodeContextMenu, PodcastContextMenu, RefreshStatusBanner
├── Extensions/       # Date+Formatting, Duration+Formatting
├── ContentView.swift # Root tab bar (5 tabs)
└── MuninnApp.swift   # App entry point
```

### Key Services

| Service | Responsibility |
|---|---|
| `AudioPlayerManager` | AVPlayer singleton, lock screen controls, background audio |
| `DownloadManager` | URLSession background downloads, progress tracking |
| `FeedService` | RSS fetch + FeedKit parse |
| `QueueManager` | Queue CRUD, auto-advance |
| `SyncService` | iCloud Drive JSON sync |
| `RefreshManager` | Background feed refresh |
| `NetworkMonitor` | NWPathMonitor, offline state |
| `ImageCache` | Async podcast artwork cache (memory + disk) |
| `StatsService` | Listening stats tracking |
| `LocalTranscriptionService` | iOS 26+ on-device transcription via SpeechAnalyzer; one episode at a time |
| `AutoTranscriptionQueue` | FIFO queue for post-download auto-transcription; must be registered in MuninnApp |

## Key Conventions

- **Files stay under 300 lines** — extract subviews/components early
- **DRY** — shared episode row components, context menus, formatters
- SwiftData `@Model` classes; `@Query` in views; no manual CoreData
- Swift 6 concurrency — use `@MainActor` where needed, avoid data races
- `AudioPlayerManager` and `NetworkMonitor` are singletons accessed via `.shared`

## Gotchas

- **`htmlStripped` is slow** — uses NSAttributedString/WebKit on the main thread (~200ms). Never call it in a SwiftUI `body`. Use `htmlTagsStripped` (regex, defined in `String+HTML.swift`) for UI previews; reserve `htmlStripped` for async `.task` contexts.
- **`@MainActor` Task capture** — `Task { [self] }` inside a `nonisolated` method where `self` is `@MainActor` silently pulls the whole task onto the main actor, starving the UI. Remove the capture; pass data via `@escaping @MainActor` callbacks instead.
- **SwiftUI transaction leak** — async state updates (e.g. image loads in `CachedAsyncImage`) inherit the active SwiftUI transaction. Wrap with `withTransaction(.init(animation: .easeIn(duration: 0.15))) { self.state = value }` to decouple from in-flight navigation animations.
- **SwiftData Bool** — store Boolean settings as `Int` (0/1) with a `Bool` computed wrapper; raw `Bool` properties can cause issues across SwiftData migrations.
- **App icon** — must be 8-bit RGB, no alpha channel. Alpha causes `CompileAssetCatalogVariant` failure at build time. Fix: `sips -s format jpeg icon.png --out /tmp/t.jpg && sips -s format png /tmp/t.jpg --out icon.png`
- **BGTask registration** — `BGTaskSchedulerPermittedIdentifiers` in `Info.plist` must list every task ID string. `UIBackgroundModes` needs both `fetch` and `processing`.
- **iOS 26 APIs** — `SpeechTranscriber` / `SpeechAnalyzer` require `#available(iOS 26, *)` guards and `nonisolated` on helpers called from `Task.detached`.

## Config

- **Bundle ID:** `com.personal.muninn`
- **Deployment target:** iOS 18.0
- **Swift version:** 5.9
- **Development team:** set in `project.yml` → `DEVELOPMENT_TEAM`
- **iCloud:** enabled via `Muninn/Muninn.entitlements` (container: `iCloud.com.personal.muninn`). Requires a paid Apple Developer account with the iCloud container registered in the portal. SwiftData uses `cloudKitDatabase: .none` — sync is handled independently by `SyncService` via JSON files in iCloud Drive, not CloudKit.

## Common Tasks

**Add a new view:** Create file in appropriate `Views/` subfolder, run `xcodegen generate`.

**Add a SwiftData model:** Add `@Model` class to `Models/`, add to model container in `MuninnApp.swift`.

**Add a new setting:** Add property to `AppSettings` model, expose in `SettingsView`.

**Add a new singleton service:** Call `.shared.setModelContext(context)` in the `modelContainer` `.onAppear` block in `MuninnApp.swift`, alongside existing registrations.

**iCloud sync fields:** Update `SyncService` encode/decode when adding syncable model properties.

## Test Feeds

- ATP: `https://atp.fm/episodes?format=rss`
- The Talk Show: `https://daringfireball.net/thetalkshow/rss`
- Syntax: `https://feed.syntax.fm/rss`

## Docs

- `docs/PROGRESS.md` — full milestone history and architecture decisions
- `docs/PERFORMANCE.md` — performance notes
- `docs/EXPORT_IMPORT_GUIDE.md` — export/import format
- `docs/CRASH_LOGGING.md` — crash logging setup
