import BackgroundTasks
import SwiftData
import os

/// Manages iOS background app refresh for podcast updates
final class BackgroundRefreshManager {
    static let shared = BackgroundRefreshManager()
    static let taskIdentifier = "com.personal.podcash.refresh"

    private let logger = Logger(subsystem: "com.personal.podcash", category: "BackgroundRefresh")

    private init() {}

    // MARK: - Public Methods

    /// Register the background task with the system. Call this on app launch.
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { return }
            self?.handleAppRefresh(task: task)
        }
        logger.info("Background refresh task registered")
    }

    /// Schedule the next background refresh. Call after completing a refresh or on app launch.
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        // Schedule for 4-6 hours from now
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60) // 4 hours

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Background refresh scheduled for \(request.earliestBeginDate?.description ?? "unknown")")
        } catch {
            logger.error("Failed to schedule background refresh: \(error.localizedDescription)")
        }
    }

    /// Cancel any pending background refresh tasks
    func cancelPendingRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        logger.info("Pending background refresh cancelled")
    }

    // MARK: - Private Methods

    private func handleAppRefresh(task: BGAppRefreshTask) {
        logger.info("Background refresh task started")

        // Schedule the next refresh before we do anything else
        scheduleAppRefresh()

        // Create a task to perform the refresh
        let refreshTask = Task {
            await performRefresh()
        }

        // Handle task expiration
        task.expirationHandler = {
            self.logger.warning("Background refresh task expired")
            refreshTask.cancel()
        }

        // Wait for the refresh to complete
        Task {
            await refreshTask.value
            task.setTaskCompleted(success: true)
            logger.info("Background refresh task completed")
        }
    }

    @MainActor
    private func performRefresh() async {
        // We need a ModelContainer to perform the refresh
        // This is a simplified approach - in production you might want to use the app's shared container
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

        guard let container = try? ModelContainer(for: schema, configurations: [modelConfiguration]) else {
            logger.error("Failed to create ModelContainer for background refresh")
            return
        }

        let context = container.mainContext

        // Perform the refresh
        let newEpisodeCount = await FeedService.shared.refreshAllPodcasts(context: context)
        logger.info("Background refresh found \(newEpisodeCount) new episodes")

        // Update the last refresh timestamp
        let settings = AppSettings.getOrCreate(context: context)
        settings.lastGlobalRefresh = Date()
        try? context.save()
    }
}
