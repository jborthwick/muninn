import SwiftData

enum PlaylistDetailBatchActions {
    static func playNext(_ episodes: [Episode]) {
        for episode in episodes.reversed() {
            QueueManager.shared.playNext(episode)
        }
    }

    static func addToQueue(_ episodes: [Episode]) {
        for episode in episodes {
            QueueManager.shared.addToQueue(episode)
        }
    }

    static func download(
        _ episodes: [Episode],
        context: ModelContext
    ) -> [Episode] {
        var needsConfirmation: [Episode] = []
        for episode in episodes where episode.localFilePath == nil && episode.downloadProgress == nil {
            let result = DownloadManager.shared.checkDownloadAllowed(episode, isAutoDownload: false, context: context)
            switch result {
            case .started:
                DownloadManager.shared.download(episode)
            case .needsConfirmation:
                needsConfirmation.append(episode)
            default:
                break
            }
        }
        return needsConfirmation
    }

    static func deleteDownloads(_ episodes: [Episode], context: ModelContext) {
        for episode in episodes where episode.localFilePath != nil {
            DownloadManager.shared.deleteDownload(episode, context: context)
        }
    }

    static func markPlayed(_ episodes: [Episode], played: Bool, context: ModelContext) {
        for episode in episodes {
            episode.isPlayed = played
        }
        try? context.save()
    }

    static func setStarred(_ episodes: [Episode], starred: Bool, context: ModelContext) {
        for episode in episodes {
            episode.isStarred = starred
            if starred && episode.localFilePath == nil {
                DownloadManager.shared.downloadWithCheck(episode, isAutoDownload: true, context: context)
            }
        }
        try? context.save()
    }

    static func removeFromPlaylist(_ episodes: [Episode], items: [PlaylistItem]) {
        let guids = Set(episodes.map(\.guid))
        for item in items where guids.contains(item.episode?.guid ?? "") {
            PlaylistManager.shared.removeItem(item)
        }
    }
}
