import BackgroundTasks
import SwiftData
import os

/// User-initiated episode preparation using BGContinuedProcessingTask.
/// Covers manual download → transcribe → chapters pipelines and explicit transcribe taps.
@MainActor
final class EpisodeContinuedProcessing {
    static let shared = EpisodeContinuedProcessing()

    private let logger = Logger(subsystem: "com.personal.muninn", category: "ContinuedProcessing")
    private var pipelines: [String: Pipeline] = [:]

    private init() {}

    // MARK: - Public API

    /// Manual download when auto-transcribe is enabled.
    func beginPrepareIfEligible(episode: Episode, context: ModelContext) {
        let settings = AppSettings.getOrCreate(context: context)
        guard settings.autoTranscribeEnabled, LocalTranscriptionService.isSupported else { return }
        guard Self.needsTranscript(episode) else { return }

        startPipeline(
            episode: episode,
            context: context,
            includesDownload: episode.localFilePath == nil,
            includesTranscription: true,
            includesChapters: settings.autoGenerateChaptersEnabled && episode.localChaptersPath == nil,
            title: "Preparing Episode"
        )
    }

    /// Explicit transcribe tap (downloaded or not).
    func beginTranscribe(episode: Episode, context: ModelContext) {
        guard LocalTranscriptionService.isSupported else { return }
        guard Self.needsTranscript(episode) else { return }

        let settings = AppSettings.getOrCreate(context: context)
        if episode.localFilePath == nil {
            AutoTranscriptionQueue.shared.requestTranscribeAfterDownload(guid: episode.guid)
        }

        startPipeline(
            episode: episode,
            context: context,
            includesDownload: episode.localFilePath == nil,
            includesTranscription: true,
            includesChapters: settings.autoGenerateChaptersEnabled && episode.localChaptersPath == nil,
            title: "Transcribing Episode"
        )
    }

    /// True while a user-initiated BGContinuedProcessingTask pipeline is running.
    var hasActivePipelines: Bool { !pipelines.isEmpty }

    func cancelPipeline(for episodeGUID: String) {
        let key = Self.pipelineKey(for: episodeGUID)
        guard let pipeline = pipelines[key] else { return }
        pipeline.pipelineTask?.cancel()
        pipeline.continuedTask?.setTaskCompleted(success: false)
        pipelines.removeValue(forKey: key)
    }

    // MARK: - Pipeline lifecycle

    private struct Pipeline {
        let taskIdentifier: String
        let episodeGUID: String
        let episodeTitle: String
        let includesDownload: Bool
        let includesTranscription: Bool
        let includesChapters: Bool
        let title: String
        var continuedTask: BGContinuedProcessingTask?
        var pipelineTask: Task<Void, Never>?
    }

    private func startPipeline(
        episode: Episode,
        context: ModelContext,
        includesDownload: Bool,
        includesTranscription: Bool,
        includesChapters: Bool,
        title: String
    ) {
        let key = Self.pipelineKey(for: episode.guid)
        guard pipelines[key] == nil else {
            logger.info("Pipeline already active for: \(episode.title)")
            return
        }

        let taskID = Self.makeTaskIdentifier(for: episode.guid)
        registerLaunchHandler(for: taskID)

        let request = BGContinuedProcessingTaskRequest(
            identifier: taskID,
            title: title,
            subtitle: episode.title
        )
        request.strategy = .queue

        var pipeline = Pipeline(
            taskIdentifier: taskID,
            episodeGUID: episode.guid,
            episodeTitle: episode.title,
            includesDownload: includesDownload,
            includesTranscription: includesTranscription,
            includesChapters: includesChapters,
            title: title
        )

        pipelines[key] = pipeline

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Failed to submit continued processing task: \(error.localizedDescription)")
            pipeline.pipelineTask = Task { await self.runPipeline(key: key, context: context) }
            pipelines[key] = pipeline
            return
        }

        pipeline.pipelineTask = Task { await self.runPipeline(key: key, context: context) }
        pipelines[key] = pipeline
        logger.info("Continued processing started for: \(episode.title)")
    }

    /// BGContinuedProcessingTask requires a per-job launch handler registered before submit.
    private func registerLaunchHandler(for taskID: String) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            Task { @MainActor in
                self.attachContinuedTask(task as? BGContinuedProcessingTask)
            }
        }
    }

    private func attachContinuedTask(_ task: BGContinuedProcessingTask?) {
        guard let task else { return }
        guard let key = pipelines.first(where: { $0.value.taskIdentifier == task.identifier })?.key else {
            logger.warning("No pipeline for continued task: \(task.identifier)")
            return
        }
        guard var pipeline = pipelines[key] else { return }

        pipeline.continuedTask = task
        task.progress.totalUnitCount = 100
        pipelines[key] = pipeline

        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, let active = self.pipelines[key] else { return }
                self.logger.warning("Continued processing expired for: \(active.episodeGUID)")
                self.cancelPipeline(for: active.episodeGUID)
            }
        }
    }

    private func runPipeline(key: String, context: ModelContext) async {
        guard let pipeline = pipelines[key] else { return }
        let guid = pipeline.episodeGUID
        var succeeded = true

        defer { completePipeline(key: key, success: succeeded) }

        if pipeline.includesDownload {
            updateProgress(key: key, fraction: 0.02, subtitle: "Downloading…")
            guard await waitForDownload(guid: guid, context: context) else {
                succeeded = false
                return
            }
        }

        if pipeline.includesTranscription {
            guard let episode = Self.fetchEpisode(guid: guid, context: context) else {
                succeeded = false
                return
            }
            if Self.needsTranscript(episode) {
                updateProgress(key: key, fraction: 0.35, subtitle: "Transcribing…")
                await ensureTranscription(episode: episode, context: context)
                guard await waitForTranscription(guid: guid, context: context) else {
                    succeeded = false
                    return
                }
            }
        }

        if pipeline.includesChapters {
            guard let episode = Self.fetchEpisode(guid: guid, context: context),
                  episode.localChaptersPath == nil else { return }
            updateProgress(key: key, fraction: 0.85, subtitle: "Generating chapters…")
            await ensureChapters(episode: episode, context: context)
            guard await waitForChapters(guid: guid, context: context) else {
                succeeded = false
                return
            }
        }

        updateProgress(key: key, fraction: 1.0, subtitle: "Done")
    }

    private func completePipeline(key: String, success: Bool) {
        pipelines[key]?.continuedTask?.setTaskCompleted(success: success)
        pipelines.removeValue(forKey: key)
    }

    // MARK: - Progress

    private func updateProgress(key: String, fraction: Double, subtitle: String) {
        guard let pipeline = pipelines[key] else { return }
        let clamped = min(max(fraction, 0), 1)
        if let task = pipeline.continuedTask {
            task.progress.completedUnitCount = Int64(clamped * 100)
            task.updateTitle(pipeline.title, subtitle: subtitle)
        }
    }

    // MARK: - Phase waiters

    private func waitForDownload(guid: String, context: ModelContext) async -> Bool {
        while !Task.isCancelled {
            guard let episode = Self.fetchEpisode(guid: guid, context: context) else { return false }
            if episode.localFilePath != nil { return true }
            if episode.downloadProgress == nil { return false }
            updateProgress(key: Self.pipelineKey(for: guid), fraction: (episode.downloadProgress ?? 0) * 0.3, subtitle: "Downloading…")
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private func waitForTranscription(guid: String, context: ModelContext) async -> Bool {
        let service = LocalTranscriptionService.shared
        while !Task.isCancelled {
            guard let episode = Self.fetchEpisode(guid: guid, context: context) else { return false }
            if !Self.needsTranscript(episode) { return true }

            let base: Double = 0.35
            let span: Double = 0.45
            let progress = episode.transcriptionProgress ?? service.progress
            updateProgress(key: Self.pipelineKey(for: guid), fraction: base + progress * span, subtitle: "Transcribing…")

            let active = service.isActivelyTranscribing(episodeGUID: guid)
            let queued = AutoTranscriptionQueue.shared.queuePosition(for: guid) != nil
            if !active, !queued, episode.transcriptionProgress == nil {
                return false
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private func waitForChapters(guid: String, context: ModelContext) async -> Bool {
        let service = ChapterService.shared
        while !Task.isCancelled {
            guard let episode = Self.fetchEpisode(guid: guid, context: context) else { return false }
            if episode.localChaptersPath != nil { return true }
            updateProgress(key: Self.pipelineKey(for: guid), fraction: 0.9, subtitle: "Generating chapters…")
            if !service.isGenerating(for: guid),
               AutoChapterQueue.shared.queuePosition(for: guid) == nil {
                return episode.localChaptersPath != nil
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    private func ensureTranscription(episode: Episode, context: ModelContext) async {
        let service = LocalTranscriptionService.shared
        let queue = AutoTranscriptionQueue.shared
        guard !service.isActivelyTranscribing(episodeGUID: episode.guid),
              queue.queuePosition(for: episode.guid) == nil else { return }
        queue.enqueue(episode: episode, context: context)
    }

    private func ensureChapters(episode: Episode, context: ModelContext) async {
        let service = ChapterService.shared
        let queue = AutoChapterQueue.shared
        guard episode.localChaptersPath == nil,
              !service.isGenerating(for: episode.guid),
              queue.queuePosition(for: episode.guid) == nil else { return }
        queue.enqueueIfEnabled(episode: episode, context: context)
    }

    // MARK: - Helpers

    private static func needsTranscript(_ episode: Episode) -> Bool {
        guard episode.localTranscriptPath != nil,
              let url = episode.localTranscriptURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return true
        }
        return false
    }

    private static func fetchEpisode(guid: String, context: ModelContext) -> Episode? {
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        return try? context.fetch(descriptor).first
    }

    static func makeTaskIdentifier(for guid: String) -> String {
        let suffix = sanitizedGUID(guid)
        let stamp = UInt64(Date().timeIntervalSince1970 * 1000)
        return "com.personal.muninn.prepare.\(suffix).\(stamp)"
    }

    static func pipelineKey(for guid: String) -> String {
        sanitizedGUID(guid)
    }

    private static func sanitizedGUID(_ guid: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        return String(
            guid.unicodeScalars
                .filter { allowed.contains($0) }
                .map(Character.init)
                .prefix(128)
        )
    }
}
