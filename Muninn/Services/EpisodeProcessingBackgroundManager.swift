import BackgroundTasks
import SwiftData
import UIKit
import os

/// Extends transcription and chapter generation into the background via beginBackgroundTask
/// and BGProcessingTask, and resumes interrupted work on relaunch.
@MainActor
final class EpisodeProcessingBackgroundManager {
    static let shared = EpisodeProcessingBackgroundManager()
    static let taskIdentifier = "com.personal.muninn.processing"

    private let logger = Logger(subsystem: "com.personal.muninn", category: "EpisodeProcessingBG")
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var lifecycleObservers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Registration

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in
                await self?.handleProcessingTask(task)
            }
        }
        logger.info("Background processing task registered")
    }

    func setupLifecycleObservers() {
        guard lifecycleObservers.isEmpty else { return }

        let center = NotificationCenter.default
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.beginBackgroundExecutionIfNeeded()
                }
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.endBackgroundExecution()
                }
            }
        )
    }

    // MARK: - Public API

    func scheduleProcessingIfNeeded() {
        guard hasActiveOrPendingWork() || PendingWorkStore.hasPendingWork else { return }

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)

        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Background processing scheduled")
        } catch {
            logger.error("Failed to schedule background processing: \(error.localizedDescription)")
        }
    }

    func resumeInterruptedWork(context: ModelContext) {
        AutoTranscriptionQueue.shared.setModelContext(context)
        AutoChapterQueue.shared.setModelContext(context)
        AutoTranscriptionQueue.shared.resumePersistedWork(context: context)
        AutoChapterQueue.shared.resumePersistedWork(context: context)
        scheduleProcessingIfNeeded()
    }

    func notifyWorkStateChanged() {
        if hasActiveOrPendingWork() {
            beginBackgroundExecutionIfNeeded()
            scheduleProcessingIfNeeded()
        } else {
            endBackgroundExecution()
        }
    }

    // MARK: - beginBackgroundTask

    private func beginBackgroundExecutionIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        guard hasActiveOrPendingWork() else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "EpisodeProcessing") { [weak self] in
            Task { @MainActor in
                self?.logger.warning("beginBackgroundTask expired — scheduling BGProcessingTask")
                self?.scheduleProcessingIfNeeded()
                self?.endBackgroundExecution()
            }
        }
        logger.info("beginBackgroundTask started for episode processing")
    }

    private func endBackgroundExecution() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - BGProcessingTask

    private func handleProcessingTask(_ task: BGProcessingTask) async {
        logger.info("BGProcessingTask started")
        scheduleProcessingIfNeeded()

        let work = Task {
            await self.runPendingProcessing()
        }

        task.expirationHandler = {
            self.logger.warning("BGProcessingTask expired")
            work.cancel()
        }

        await work.value
        task.setTaskCompleted(success: !work.isCancelled)
        logger.info("BGProcessingTask completed")
    }

    private func runPendingProcessing() async {
        guard let container = Self.makeModelContainer() else {
            logger.error("Failed to create ModelContainer for background processing")
            return
        }

        let context = container.mainContext
        resumeInterruptedWork(context: context)
        await waitForQueuesToDrain()
        scheduleProcessingIfNeeded()
    }

    private func waitForQueuesToDrain() async {
        let transcription = AutoTranscriptionQueue.shared
        let chapters = AutoChapterQueue.shared

        while !Task.isCancelled {
            let transcriptionIdle = !transcription.isProcessing && transcription.queuedGUIDs.isEmpty
            let chaptersIdle = !chapters.isProcessing && chapters.queuedGUIDs.isEmpty
            if transcriptionIdle && chaptersIdle { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - Helpers

    private func hasActiveOrPendingWork() -> Bool {
        let transcription = AutoTranscriptionQueue.shared
        let chapters = AutoChapterQueue.shared
        return transcription.isProcessing
            || chapters.isProcessing
            || !transcription.queuedGUIDs.isEmpty
            || !chapters.queuedGUIDs.isEmpty
    }

    private static func makeModelContainer() -> ModelContainer? {
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
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try? ModelContainer(for: schema, configurations: [config])
    }
}
