import Foundation
import Speech
import AVFoundation
import SwiftData
import os

@MainActor
@Observable
final class LocalTranscriptionService {
    static let shared = LocalTranscriptionService()
    private init() {}

    private let logger = Logger(subsystem: "com.muninn", category: "LocalTranscription")

    // MARK: - Observable State

    private(set) var isTranscribing = false
    private(set) var progress: Double = 0        // 0.0 – 1.0
    private(set) var error: String?
    private(set) var transcribingEpisodeGUID: String?

    // MARK: - Availability

    /// True on iOS 26+ with a device that supports SpeechTranscriber.
    nonisolated static var isSupported: Bool {
        if #available(iOS 26, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    // MARK: - Public API

    /// Transcribes the episode's downloaded audio file using SpeechAnalyzer (iOS 26+).
    /// Saves the result to disk and sets `episode.localTranscriptPath`.
    /// Returns `false` if transcription was skipped (already in progress or unavailable).
    @discardableResult
    func transcribe(episode: Episode, context: ModelContext) async -> Bool {
        guard #available(iOS 26, *) else {
            error = "On-device transcription requires iOS 26 or later."
            return false
        }
        guard let audioURL = episode.localFileURL else {
            error = "Episode must be downloaded before it can be transcribed."
            return false
        }
        guard !isTranscribing else { return false }

        isTranscribing = true
        progress = 0
        error = nil
        transcribingEpisodeGUID = episode.guid
        episode.transcriptionProgress = 0

        defer {
            isTranscribing = false
            transcribingEpisodeGUID = nil
            progress = 0
        }

        // Request speech recognition authorization
        let authStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authStatus == .authorized else {
            error = "Speech recognition permission is required. Please enable it in Settings > Muninn."
            episode.transcriptionProgress = nil
            return false
        }

        do {
            let segments = try await runSpeechAnalyzer(
                audioURL: audioURL,
                estimatedDuration: episode.duration ?? 3600,
                onProgress: { [weak self] p in
                    self?.progress = p
                    episode.transcriptionProgress = p
                }
            )

            guard !segments.isEmpty else {
                error = "No speech was detected in this episode."
                episode.transcriptionProgress = nil
                return false
            }

            // Save transcript off main thread — JSON encode + file write can be slow
            let guid = episode.guid
            let filename = try await Task.detached { [self] in
                try self.saveTranscriptToDisk(segments: segments, guid: guid)
            }.value

            episode.localTranscriptPath = filename
            episode.transcriptionProgress = nil
            try? context.save()
            logger.info("Transcript saved: \(filename) (\(segments.count) segments)")
            return true
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)")
            self.error = "Transcription failed: \(error.localizedDescription)"
            episode.transcriptionProgress = nil
            return false
        }
    }

    // MARK: - SpeechAnalyzer (iOS 26+)

    @available(iOS 26, *)
    nonisolated private func runSpeechAnalyzer(
        audioURL: URL,
        estimatedDuration: TimeInterval,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        // Verify device support and locale
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.notAvailable
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw TranscriptionError.unsupportedLocale
        }

        // Create transcriber
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)

        // Download model assets if not already installed
        if let installRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            logger.info("Downloading speech model assets…")
            try await installRequest.downloadAndInstall()
        }

        // Create analyzer with the transcriber module
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Open the audio file (SpeechAnalyzer handles format conversion automatically)
        let audioFile = try AVAudioFile(forReading: audioURL)

        // Consume results concurrently — transcriber.results is an AsyncSequence
        // that terminates when the analyzer is finalized.
        //
        // NOTE: No [self] or Episode capture here — those are @MainActor-bound and
        // capturing them would pull this Task onto the main actor, starving the UI.
        // Progress is delivered via the @MainActor `onProgress` callback instead.
        let resultsTask = Task { () -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            var lastReportedProgress: Double = 0

            for try await result in transcriber.results {
                let attrText = result.text
                let plainText = String(attrText.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !plainText.isEmpty else { continue }

                // Extract start/end time from AttributedString run attributes.
                // Each run carries an AttributeScopes.SpeechAttributes.TimeRangeAttribute
                // whose value is a CMTimeRange for that span of text.
                var firstStart: CMTime?
                var lastEnd: CMTime?
                for run in attrText.runs {
                    if let cmRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] {
                        if firstStart == nil { firstStart = cmRange.start }
                        lastEnd = cmRange.end
                    }
                }

                let startSecs = firstStart?.seconds ?? 0
                let endSecs   = lastEnd?.seconds   ?? (startSecs + 5)

                segments.append(TranscriptSegment(
                    startTime: startSecs,
                    endTime: endSecs,
                    text: plainText,
                    speaker: nil
                ))

                // Throttle: only hop to main actor when progress advances by ≥1%.
                // This prevents hundreds of SwiftData writes and SwiftUI re-renders
                // per second from starving gesture and navigation processing.
                if endSecs > 0, estimatedDuration > 0 {
                    let newProgress = min(endSecs / estimatedDuration, 0.99)
                    if newProgress - lastReportedProgress >= 0.01 {
                        lastReportedProgress = newProgress
                        await MainActor.run { onProgress(newProgress) }
                    }
                }
            }
            return segments
        }

        // Feed the audio file into the analyzer — returns after the entire file is read.
        let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)

        // Finalize: flushes any remaining buffered results and terminates transcriber.results,
        // which causes the resultsTask loop above to exit.
        if let lastSampleTime {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let segments = try await resultsTask.value
        await MainActor.run { onProgress(1.0) }
        return segments
    }

    // MARK: - Errors

    private enum TranscriptionError: LocalizedError {
        case notAvailable
        case unsupportedLocale

        var errorDescription: String? {
            switch self {
            case .notAvailable:
                return "On-device transcription is not available on this device."
            case .unsupportedLocale:
                return "Transcription is not available for your current language."
            }
        }
    }

    // MARK: - Disk Persistence

    nonisolated private func transcriptsDirectory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Saves segments in Podcast Index JSON format so `TranscriptService.parsePodcastIndexJSON` can load them.
    nonisolated private func saveTranscriptToDisk(segments: [TranscriptSegment], guid: String) throws -> String {
        struct JSONTranscript: Encodable {
            struct JSONSegment: Encodable {
                let startTime: TimeInterval
                let endTime: TimeInterval
                let body: String
            }
            let segments: [JSONSegment]
        }

        let json = JSONTranscript(segments: segments.map {
            .init(startTime: $0.startTime, endTime: $0.endTime, body: $0.text)
        })

        let data = try JSONEncoder().encode(json)
        let filename = sanitizedFilename(for: guid) + ".json"
        let fileURL = try transcriptsDirectory().appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return filename
    }

    nonisolated private func sanitizedFilename(for guid: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        return String(
            guid.unicodeScalars
                .filter { allowed.contains($0) }
                .map(Character.init)
                .prefix(128)
        )
    }
}
