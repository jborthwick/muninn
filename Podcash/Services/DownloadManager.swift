import Foundation
import SwiftData
import os

/// Result of attempting to start a download
enum DownloadResult {
    case started
    case alreadyDownloaded
    case alreadyDownloading
    case blocked(reason: String)
    case needsConfirmation
}

/// Manages episode downloads with background URLSession support
final class DownloadManager: NSObject {
    static let shared = DownloadManager()

    private let logger = AppLogger.download
    private var urlSession: URLSession!
    private var activeDownloads: [URL: DownloadTask] = [:]

    private let fileManager = FileManager.default

    struct DownloadTask {
        let episodeGUID: String
        let task: URLSessionDownloadTask
        var progressHandler: ((Double) -> Void)?
    }

    private override init() {
        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: "com.personal.podcash.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public Methods

    /// Checks if a download can proceed based on network preferences
    /// - Parameters:
    ///   - episode: The episode to download
    ///   - isAutoDownload: Whether this is an automatic download (uses different preference)
    ///   - context: ModelContext to fetch settings
    /// - Returns: DownloadResult indicating whether to proceed
    func checkDownloadAllowed(_ episode: Episode, isAutoDownload: Bool = false, context: ModelContext) -> DownloadResult {
        guard URL(string: episode.audioURL) != nil else {
            return .blocked(reason: "Invalid URL")
        }

        // Skip if already downloaded
        if episode.localFilePath != nil {
            return .alreadyDownloaded
        }

        // Skip if already downloading
        if let url = URL(string: episode.audioURL), activeDownloads[url] != nil {
            return .alreadyDownloading
        }

        // Check network preference
        let settings = AppSettings.getOrCreate(context: context)
        let preference = isAutoDownload ? settings.autoDownloadPreference : settings.downloadPreference
        let connectionType = NetworkMonitor.shared.connectionType

        if connectionType == .cellular {
            switch preference {
            case .wifiOnly:
                return .blocked(reason: "WiFi only")
            case .askOnCellular:
                return .needsConfirmation
            case .always:
                break // proceed
            }
        }

        return .started
    }

    /// Downloads an episode (bypasses network preference check - use checkDownloadAllowed first)
    func download(_ episode: Episode) {
        startDownload(episode)
    }

    /// Downloads an episode with network preference checking
    /// - Returns: DownloadResult indicating what happened
    @discardableResult
    func downloadWithCheck(_ episode: Episode, isAutoDownload: Bool = false, context: ModelContext) -> DownloadResult {
        let result = checkDownloadAllowed(episode, isAutoDownload: isAutoDownload, context: context)

        switch result {
        case .started:
            startDownload(episode)
        case .alreadyDownloaded, .alreadyDownloading, .blocked, .needsConfirmation:
            break
        }

        return result
    }

    /// Internal method to start the actual download
    private func startDownload(_ episode: Episode) {
        guard let url = URL(string: episode.audioURL) else { return }

        // Skip if already downloaded
        if episode.localFilePath != nil { return }

        // Skip if already downloading
        if activeDownloads[url] != nil { return }

        let task = urlSession.downloadTask(with: url)
        activeDownloads[url] = DownloadTask(
            episodeGUID: episode.guid,
            task: task,
            progressHandler: { [weak episode] progress in
                DispatchQueue.main.async {
                    episode?.downloadProgress = progress
                }
            }
        )

        DispatchQueue.main.async {
            episode.downloadProgress = 0
        }

        task.resume()
    }

    /// Cancels a download in progress
    func cancelDownload(_ episode: Episode) {
        guard let url = URL(string: episode.audioURL),
              let downloadTask = activeDownloads[url] else { return }

        downloadTask.task.cancel()
        activeDownloads.removeValue(forKey: url)

        DispatchQueue.main.async {
            episode.downloadProgress = nil
        }
    }

    /// Deletes a downloaded episode
    func deleteDownload(_ episode: Episode) {
        guard let fileURL = episode.localFileURL else { return }

        do {
            try fileManager.removeItem(at: fileURL)
            logger.info("Deleted download for episode: \(episode.title)")
        } catch {
            logger.error("Failed to delete download file: \(error.localizedDescription)")
        }

        DispatchQueue.main.async {
            episode.localFilePath = nil
            episode.downloadProgress = nil
        }
    }

    /// Deletes all downloads for a podcast
    func deleteDownloads(for podcast: Podcast) {
        for episode in podcast.episodes {
            deleteDownload(episode)
        }
    }

    /// Deletes all downloads
    func deleteAllDownloads(context: ModelContext) {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.localFilePath != nil }
        )

        if let episodes = try? context.fetch(descriptor) {
            for episode in episodes {
                deleteDownload(episode)
            }
        }
    }

    /// Returns total size of all downloads in bytes
    func totalDownloadSize(context: ModelContext) -> Int64 {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.localFilePath != nil }
        )

        guard let episodes = try? context.fetch(descriptor) else { return 0 }

        var totalSize: Int64 = 0
        for episode in episodes {
            if let fileURL = episode.localFileURL {
                if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let size = attrs[.size] as? Int64 {
                    totalSize += size
                }
            }
        }
        return totalSize
    }

    /// Migrates old absolute paths to just filenames
    /// Call this on app launch to fix existing downloads
    func migrateLocalPaths(context: ModelContext) {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.localFilePath != nil }
        )

        guard let episodes = try? context.fetch(descriptor) else { return }

        var migratedCount = 0
        for episode in episodes {
            guard let oldPath = episode.localFilePath else { continue }

            // Check if this looks like an absolute path (contains "/")
            if oldPath.contains("/") {
                // Extract just the filename
                let filename = (oldPath as NSString).lastPathComponent
                episode.localFilePath = filename
                migratedCount += 1
                logger.info("Migrated path for episode: \(episode.title)")
            }
        }

        if migratedCount > 0 {
            try? context.save()
            logger.info("Migrated \(migratedCount) episode paths from absolute to relative")
        }
    }

    // MARK: - Private Methods

    private func downloadsDirectory() -> URL {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadsPath = documentsPath.appendingPathComponent("Downloads", isDirectory: true)

        if !fileManager.fileExists(atPath: downloadsPath.path) {
            do {
                try fileManager.createDirectory(at: downloadsPath, withIntermediateDirectories: true)
            } catch {
                logger.error("Failed to create downloads directory: \(error.localizedDescription)")
            }
        }

        return downloadsPath
    }

    private func localFileURL(for guid: String, originalURL: URL) -> URL {
        let ext = originalURL.pathExtension.isEmpty ? "mp3" : originalURL.pathExtension
        let sanitizedGUID = guid.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return downloadsDirectory().appendingPathComponent("\(sanitizedGUID).\(ext)")
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let url = downloadTask.originalRequest?.url,
              let download = activeDownloads[url] else { return }

        let destinationURL = localFileURL(for: download.episodeGUID, originalURL: url)

        // Remove existing file if any
        try? fileManager.removeItem(at: destinationURL)

        do {
            try fileManager.moveItem(at: location, to: destinationURL)
            logger.info("Download completed for episode: \(download.episodeGUID)")

            // Store just the filename, not the full path (iOS paths change between app launches)
            let filename = destinationURL.lastPathComponent

            DispatchQueue.main.async {
                // Update episode with local path
                // Note: We need to find the episode by GUID and update it
                NotificationCenter.default.post(
                    name: .downloadCompleted,
                    object: nil,
                    userInfo: [
                        "guid": download.episodeGUID,
                        "localPath": filename
                    ]
                )
            }
        } catch {
            logger.error("Failed to move downloaded file: \(error.localizedDescription)")
        }

        activeDownloads.removeValue(forKey: url)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let url = downloadTask.originalRequest?.url,
              let download = activeDownloads[url] else { return }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        DispatchQueue.main.async {
            download.progressHandler?(progress)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let url = task.originalRequest?.url else { return }

        if let error = error {
            logger.error("Download failed for URL \(url.absoluteString): \(error.localizedDescription)")

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .downloadFailed,
                    object: nil,
                    userInfo: ["url": url, "error": error]
                )
            }
        }

        activeDownloads.removeValue(forKey: url)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Handle background session completion
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .backgroundDownloadsCompleted, object: nil)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let downloadCompleted = Notification.Name("downloadCompleted")
    static let downloadFailed = Notification.Name("downloadFailed")
    static let backgroundDownloadsCompleted = Notification.Name("backgroundDownloadsCompleted")
    static let episodePlaybackCompleted = Notification.Name("episodePlaybackCompleted")
}
