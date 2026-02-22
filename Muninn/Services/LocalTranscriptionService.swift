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
    static var isSupported: Bool {
        if #available(iOS 26, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    // MARK: - Public API

    /// Transcribes the episode's downloaded audio file using SpeechAnalyzer (iOS 26+).
    /// Saves the result to disk and sets `episode.localTranscriptPath`.
    func transcribe(episode: Episode, context: ModelContext) async {
        guard #available(iOS 26, *) else {
            error = "On-device transcription requires iOS 26 or later."
            return
        }
        guard let audioURL = episode.localFileURL else {
            error = "Episode must be downloaded before it can be transcribed."
            return
        }
        guard !isTranscribing else { return }

        isTranscribing = true
        progress = 0
        error = nil
        transcribingEpisodeGUID = episode.guid

        defer {
            isTranscribing = false
            transcribingEpisodeGUID = nil
        }

        // Request speech recognition authorization
        let authStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authStatus == .authorized else {
            error = "Speech recognition permission is required. Please enable it in Settings > Muninn."
            return
        }

        do {
            let segments = try await runSpeechAnalyzer(
                audioURL: audioURL,
                estimatedDuration: episode.duration ?? 3600
            )

            guard !segments.isEmpty else {
                error = "No speech was detected in this episode."
                return
            }

            let filename = try saveTranscriptToDisk(segments: segments, guid: episode.guid)
            episode.localTranscriptPath = filename
            try? context.save()
            logger.info("Transcript saved: \(filename) (\(segments.count) segments)")
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)")
            self.error = "Transcription failed: \(error.localizedDescription)"
        }
    }

    // MARK: - SpeechAnalyzer (iOS 26+)

    @available(iOS 26, *)
    private func runSpeechAnalyzer(audioURL: URL, estimatedDuration: TimeInterval) async throws -> [TranscriptSegment] {
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
        let resultsTask = Task { [self] () -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
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

                if endSecs > 0, estimatedDuration > 0 {
                    progress = min(endSecs / estimatedDuration, 0.99)
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
        progress = 1.0
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

    private func transcriptsDirectory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Saves segments in Podcast Index JSON format so `TranscriptService.parsePodcastIndexJSON` can load them.
    private func saveTranscriptToDisk(segments: [TranscriptSegment], guid: String) throws -> String {
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

    private func sanitizedFilename(for guid: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        return String(
            guid.unicodeScalars
                .filter { allowed.contains($0) }
                .map(Character.init)
                .prefix(128)
        )
    }
}
