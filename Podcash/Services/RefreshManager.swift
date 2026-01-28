import Foundation
import SwiftData

@MainActor
@Observable
final class RefreshManager {
    static let shared = RefreshManager()

    var isRefreshing = false
    var refreshProgress: Double = 0  // 0-1 progress
    var refreshedCount = 0
    var totalCount = 0
    var lastRefreshDate: Date?

    /// Number of concurrent feed fetches
    private let concurrentFetches = 6

    private init() {}

    /// Triggers a background refresh of all podcasts
    func refreshAllPodcasts(context: ModelContext) {
        guard !isRefreshing else { return }

        Task {
            isRefreshing = true
            refreshProgress = 0
            refreshedCount = 0

            let descriptor = FetchDescriptor<Podcast>()
            guard let podcasts = try? context.fetch(descriptor) else {
                isRefreshing = false
                return
            }

            totalCount = podcasts.count
            await refreshInParallel(podcasts: podcasts, context: context)

            lastRefreshDate = Date()
            isRefreshing = false
        }
    }

    /// Triggers a background refresh of specific podcasts
    func refreshPodcasts(_ podcasts: [Podcast], context: ModelContext) {
        guard !isRefreshing else { return }

        Task {
            isRefreshing = true
            refreshProgress = 0
            refreshedCount = 0
            totalCount = podcasts.count

            await refreshInParallel(podcasts: podcasts, context: context)

            lastRefreshDate = Date()
            isRefreshing = false
        }
    }

    /// Refresh podcasts in parallel with limited concurrency
    private func refreshInParallel(podcasts: [Podcast], context: ModelContext) async {
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var index = 0

            for podcast in podcasts {
                // Wait if we've hit the concurrency limit
                if inFlight >= concurrentFetches {
                    await group.next()
                    inFlight -= 1
                    refreshedCount += 1
                    refreshProgress = Double(refreshedCount) / Double(totalCount)
                }

                group.addTask {
                    _ = try? await FeedService.shared.refreshPodcast(podcast, context: context)
                }
                inFlight += 1
                index += 1
            }

            // Wait for remaining tasks
            for await _ in group {
                refreshedCount += 1
                refreshProgress = Double(refreshedCount) / Double(totalCount)
            }
        }
    }
}
