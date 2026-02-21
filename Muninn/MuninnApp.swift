import SwiftUI
import SwiftData

@main
struct MuninnApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Podcast.self,
            Episode.self,
            Folder.self,
            QueueItem.self,
            AppSettings.self,
            ListeningSession.self
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            print("❌ ModelContainer creation failed: \(error)")
            print("❌ Error details: \(String(describing: error))")
            
            // Try to delete the old database and all related files
            let url = modelConfiguration.url
            print("⚠️ Attempting to delete corrupted database at: \(url)")
            
            // Delete main database file
            try? FileManager.default.removeItem(at: url)
            
            // Delete WAL and SHM files (SQLite write-ahead log and shared memory)
            let walURL = url.deletingPathExtension().appendingPathExtension("sqlite-wal")
            let shmURL = url.deletingPathExtension().appendingPathExtension("sqlite-shm")
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: shmURL)
            
            print("⚠️ Deleted database files, attempting to recreate...")
            
            // Try again with fresh database
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
                    // Initialize crash reporter (must be first)
                    _ = CrashReporter.shared
                    
                    // Initialize services with model context
                    let context = sharedModelContainer.mainContext
                    DownloadObserver.shared.setModelContext(context)
                    QueueManager.shared.setModelContext(context)
                    StatsService.shared.setModelContext(context)

                    // Migrate old absolute paths to relative filenames
                    DownloadManager.shared.migrateLocalPaths(context: context)

                    // Clean up orphaned downloads (stuck downloads from previous sessions)
                    DownloadManager.shared.cleanupOrphanedDownloads(context: context)

                    // Restore active downloads from background session
                    DownloadManager.shared.restoreActiveDownloads(context: context)

                    // Register and schedule background refresh
                    BackgroundRefreshManager.shared.registerBackgroundTask()
                    BackgroundRefreshManager.shared.scheduleAppRefresh()

                    // Restore last played episode (shows mini player without playing)
                    AudioPlayerManager.shared.restoreLastEpisode(from: context)
                }
                .task {
                    let context = sharedModelContainer.mainContext

                    // Brief delay to ensure UI is ready to show refresh banner
                    try? await Task.sleep(for: .milliseconds(500))

                    // Sync on app launch if iCloud is available
                    if SyncService.shared.isCloudAvailable {
                        await SyncService.shared.syncNow(context: context)
                    }

                    // Background refresh if stale (> 1 hour since last refresh)
                    // Use RefreshManager so the status banner shows
                    let settings = AppSettings.getOrCreate(context: context)
                    let staleThreshold = Date().addingTimeInterval(-3600) // 1 hour
                    if settings.lastGlobalRefresh ?? .distantPast < staleThreshold {
                        RefreshManager.shared.refreshAllPodcasts(context: context)
                        settings.lastGlobalRefresh = Date()
                        try? context.save()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
