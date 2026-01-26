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
                }
                .task {
                    // Sync on app launch if iCloud is available
                    if SyncService.shared.isCloudAvailable {
                        await SyncService.shared.syncNow(context: sharedModelContainer.mainContext)
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
