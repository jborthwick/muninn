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
    private var modelContext: ModelContext?

    /// When true, auto queues must not start new jobs (app resigned active).
    /// Cleared on become-active and while a BGProcessingTask is running.
    private(set) var isAutoProcessingSuspended = false

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
                    self?.handleWillResignActive()
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
                    self?.handleDidBecomeActive()
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
        modelContext = context
        AutoTranscriptionQueue.shared.setModelContext(context)
        AutoChapterQueue.shared.setModelContext(context)
        AutoTranscriptionQueue.shared.resumePersistedWork(context: context)
        AutoChapterQueue.shared.resumePersistedWork(context: context)
        scheduleProcessingIfNeeded()
    }

    func notifyWorkStateChanged() {
        // Never start a UIKit background task from work-state changes — that assertion
        // is only for a brief resign-active cleanup. Long work uses BGContinuedProcessingTask.
        if !hasActiveRunningWork() {
            endBackgroundExecution()
        }
        // Keep a BGProcessingTask armed whenever persisted work remains, even if
        // in-memory queues are idle after a background interrupt.
        scheduleProcessingIfNeeded()
    }

    // MARK: - beginBackgroundTask

    private func handleWillResignActive() {
        // User-initiated pipelines already have BGContinuedProcessingTask. Holding a
        // UIKit beginBackgroundTask for them trips the 30s warning and risk of kill.
        if EpisodeContinuedProcessing.shared.hasActivePipelines {
            logger.info("Leaving continued processing running — skipping UIKit background task")
            endBackgroundExecution()
            scheduleProcessingIfNeeded()
            return
        }

        let wasRunning = hasActiveRunningWork()
        suspendAutoProcessingIfNeeded()

        if wasRunning {
            // Brief assertion so cancel/teardown can finish, then end promptly.
            beginBriefCleanupBackgroundTask()
        } else {
            endBackgroundExecution()
        }
        scheduleProcessingIfNeeded()
    }

    /// Pause auto transcription/chapters when leaving the foreground.
    private func suspendAutoProcessingIfNeeded() {
        guard hasActiveRunningWork() || hasActiveOrPendingWork() || PendingWorkStore.hasPendingWork else {
            return
        }

        isAutoProcessingSuspended = true
        logger.info("Suspending auto episode processing for background")
        ChapterService.shared.cancelActiveGeneration()
        LocalTranscriptionService.shared.cancelActiveForBackgroundExpiry()
    }

    /// Short-lived UIKit assertion for cancel teardown only — must not outlive ~a few seconds.
    private func beginBriefCleanupBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }

        // Expiration handler is already invoked synchronously on the main thread.
        // Must end the task before returning or iOS watchdog-kills the app (0x8badf00d).
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "EpisodeProcessing") { [weak self] in
            guard let self else { return }
            self.logger.warning(
                "beginBackgroundTask expired — ending assertion and scheduling BGProcessingTask"
            )
            self.isAutoProcessingSuspended = true
            ChapterService.shared.cancelActiveGeneration()
            LocalTranscriptionService.shared.cancelActiveForBackgroundExpiry()
            self.scheduleProcessingIfNeeded()
            self.endBackgroundExecution()
        }
        logger.info("beginBackgroundTask started for brief episode-processing cleanup")

        // End well before the 30s system warning once cancel has had a chance to run.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.endBackgroundExecution()
        }
    }

    private func endBackgroundExecution() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func handleDidBecomeActive() {
        isAutoProcessingSuspended = false
        endBackgroundExecution()
        if let modelContext {
            resumeInterruptedWork(context: modelContext)
        } else {
            scheduleProcessingIfNeeded()
        }
    }

    // MARK: - BGProcessingTask

    private func handleProcessingTask(_ task: BGProcessingTask) async {
        logger.info("BGProcessingTask started")
        isAutoProcessingSuspended = false
        scheduleProcessingIfNeeded()

        let work = Task {
            await self.runPendingProcessing()
        }

        task.expirationHandler = {
            self.logger.warning("BGProcessingTask expired")
            work.cancel()
            Task { @MainActor in
                self.isAutoProcessingSuspended = true
                ChapterService.shared.cancelActiveGeneration()
                LocalTranscriptionService.shared.cancelActiveForBackgroundExpiry()
            }
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

    private func hasActiveRunningWork() -> Bool {
        AutoTranscriptionQueue.shared.isProcessing
            || AutoChapterQueue.shared.isProcessing
            || LocalTranscriptionService.shared.isTranscribing
            || ChapterService.shared.isGenerating
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
