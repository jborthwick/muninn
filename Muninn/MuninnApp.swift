import SwiftUI
import SwiftData

@main
struct MuninnApp: App {
    init() {
        // Install crash handlers before any other launch work.
        _ = CrashReporter.shared
        BackgroundRefreshManager.shared.registerBackgroundTask()
        EpisodeProcessingBackgroundManager.shared.registerBackgroundTasks()
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Podcast.self,
            Episode.self,
            Folder.self,
            Playlist.self,
            PlaylistItem.self,
            QueueItem.self,
            AppSettings.self,
            ListeningSession.self
        ])

        // Use an explicit store name ("muninn.store") so the URL is deterministic
        // and doesn't conflict with any old "default.store" from a previous module name.
        let appSupportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storeURL = appSupportDir.appendingPathComponent("muninn.store")

        // Ensure directory exists before ModelConfiguration is created
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        // cloudKitDatabase: .none — prevents SwiftData from automatically enabling CloudKit
        // sync when iCloud entitlements are present. This app uses its own JSON-based
        // iCloud sync via SyncService and does not want SwiftData's CloudKit integration.
        let modelConfiguration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            print("❌ ModelContainer creation failed: \(error)")

            // Delete the store and its WAL/SHM sidecar files, then retry.
            // SQLite WAL convention: "muninn.store" → "muninn.store-wal" / "muninn.store-shm"
            for url in [storeURL,
                        URL(fileURLWithPath: storeURL.path + "-wal"),
                        URL(fileURLWithPath: storeURL.path + "-shm")] {
                try? FileManager.default.removeItem(at: url)
            }

            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer even after deleting old database: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Services with model context (crash reporter already installed in App.init)
                    let context = sharedModelContainer.mainContext
                    DownloadObserver.shared.setModelContext(context)
                    QueueManager.shared.setModelContext(context)
                    PlaylistManager.shared.setModelContext(context)
                    StatsService.shared.setModelContext(context)
                    AutoTranscriptionQueue.shared.setModelContext(context)
                    AutoChapterQueue.shared.setModelContext(context)
                    AudioPlayerManager.shared.setModelContext(context)

                    // Migrate old absolute paths to relative filenames
                    DownloadManager.shared.migrateLocalPaths(context: context)

                    // Clean up orphaned downloads (stuck downloads from previous sessions)
                    DownloadManager.shared.cleanupOrphanedDownloads(context: context)

                    EpisodeProcessingBackgroundManager.shared.setupLifecycleObservers()
                    EpisodeProcessingBackgroundManager.shared.resumeInterruptedWork(context: context)

                    // Restore active downloads from background session
                    DownloadManager.shared.restoreActiveDownloads(context: context)

                    // Schedule background refresh
                    BackgroundRefreshManager.shared.scheduleAppRefresh()

                    // Restore last played episode (shows mini player without playing)
                    AudioPlayerManager.shared.restoreLastEpisode(from: context)
                }
                .task {
                    let context = sharedModelContainer.mainContext

                    // Let the first frames render before heavy launch work.
                    try? await Task.sleep(for: .milliseconds(500))

                    // Sync on app launch if iCloud is available
                    if SyncService.shared.isCloudAvailable {
                        await SyncService.shared.syncNow(context: context)
                    }

                    // Yield so early taps aren't starved by sync→refresh back-to-back.
                    await Task.yield()

                    // Background refresh if stale (> 1 hour since last refresh)
                    // Use RefreshManager so the status banner shows
                    let settings = AppSettings.getOrCreate(context: context)
                    let staleThreshold = Date().addingTimeInterval(-3600) // 1 hour
                    if settings.lastGlobalRefresh ?? .distantPast < staleThreshold {
                        await RefreshManager.shared.refreshAllPodcasts(context: context)
                        settings.lastGlobalRefresh = Date()
                        try? context.save()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
