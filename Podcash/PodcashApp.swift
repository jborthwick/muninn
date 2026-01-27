import SwiftUI
import SwiftData

@main
struct PodcashApp: App {
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
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Initialize services with model context
                    let context = sharedModelContainer.mainContext
                    DownloadObserver.shared.setModelContext(context)
                    QueueManager.shared.setModelContext(context)
                    StatsService.shared.setModelContext(context)

                    // Migrate old absolute paths to relative filenames
                    DownloadManager.shared.migrateLocalPaths(context: context)

                    // Register and schedule background refresh
                    BackgroundRefreshManager.shared.registerBackgroundTask()
                    BackgroundRefreshManager.shared.scheduleAppRefresh()

                    // Restore last played episode (shows mini player without playing)
                    AudioPlayerManager.shared.restoreLastEpisode(from: context)
                }
                .task {
                    let context = sharedModelContainer.mainContext

                    // Sync on app launch if iCloud is available
                    if SyncService.shared.isCloudAvailable {
                        await SyncService.shared.syncNow(context: context)
                    }

                    // Background refresh if stale (> 1 hour since last refresh)
                    let settings = AppSettings.getOrCreate(context: context)
                    let staleThreshold = Date().addingTimeInterval(-3600) // 1 hour
                    if settings.lastGlobalRefresh ?? .distantPast < staleThreshold {
                        _ = await FeedService.shared.refreshAllPodcasts(context: context)
                        settings.lastGlobalRefresh = Date()
                        try? context.save()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
