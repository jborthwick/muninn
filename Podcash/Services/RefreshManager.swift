import Foundation
import SwiftData

@Observable
final class RefreshManager {
    static let shared = RefreshManager()

    var isRefreshing = false
    var refreshProgress: Double = 0  // 0-1 progress
    var refreshedCount = 0
    var totalCount = 0
    var lastRefreshDate: Date?

    private init() {}

    /// Triggers a background refresh of all podcasts
    func refreshAllPodcasts(context: ModelContext) {
        guard !isRefreshing else { return }

        Task { @MainActor in
            isRefreshing = true
            refreshProgress = 0
            refreshedCount = 0

            let descriptor = FetchDescriptor<Podcast>()
            guard let podcasts = try? context.fetch(descriptor) else {
                isRefreshing = false
                return
            }

            totalCount = podcasts.count

            for (index, podcast) in podcasts.enumerated() {
                _ = try? await FeedService.shared.refreshPodcast(podcast, context: context)
                refreshedCount = index + 1
                refreshProgress = Double(refreshedCount) / Double(totalCount)
            }

            lastRefreshDate = Date()
            isRefreshing = false
        }
    }

    /// Triggers a background refresh of specific podcasts
    func refreshPodcasts(_ podcasts: [Podcast], context: ModelContext) {
        guard !isRefreshing else { return }

        Task { @MainActor in
            isRefreshing = true
            refreshProgress = 0
            refreshedCount = 0
            totalCount = podcasts.count

            for (index, podcast) in podcasts.enumerated() {
                _ = try? await FeedService.shared.refreshPodcast(podcast, context: context)
                refreshedCount = index + 1
                refreshProgress = Double(refreshedCount) / Double(totalCount)
            }

            lastRefreshDate = Date()
            isRefreshing = false
        }
    }
}
