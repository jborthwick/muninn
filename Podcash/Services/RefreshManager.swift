import Foundation
import SwiftData
import os

@MainActor
@Observable
final class RefreshManager {
    static let shared = RefreshManager()

    var isRefreshing = false
    var refreshProgress: Double = 0  // 0-1 progress
    var refreshedCount = 0
    var totalCount = 0
    var lastRefreshDate: Date?

    // Debug stats for last refresh
    var lastRefreshStats: (notModified: Int, fetched: Int, errors: Int) = (0, 0, 0)

    /// Number of concurrent feed fetches
    private let concurrentFetches = 6
    private let logger = Logger(subsystem: "com.personal.podcash", category: "Refresh")

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
        var notModified = 0
        var fetched = 0
        var errors = 0

        logger.info("Starting refresh of \(podcasts.count) podcasts (concurrency: \(self.concurrentFetches))")

        // Result type: -1 = not modified, >= 0 = fetched (new episode count), nil = error
        await withTaskGroup(of: Int?.self) { group in
            var inFlight = 0

            for podcast in podcasts {
                // Wait if we've hit the concurrency limit
                if inFlight >= concurrentFetches {
                    if let result = await group.next() {
                        switch result {
                        case .some(-1): notModified += 1
                        case .some(_): fetched += 1
                        case .none: errors += 1
                        }
                    }
                    inFlight -= 1
                    refreshedCount += 1
                    refreshProgress = Double(refreshedCount) / Double(totalCount)
                }

                group.addTask {
                    try? await FeedService.shared.refreshPodcast(podcast, context: context)
                }
                inFlight += 1
            }

            // Wait for remaining tasks
            for await result in group {
                switch result {
                case .some(-1): notModified += 1
                case .some(_): fetched += 1
                case .none: errors += 1
                }
                refreshedCount += 1
                refreshProgress = Double(refreshedCount) / Double(totalCount)
            }
        }

        lastRefreshStats = (notModified, fetched, errors)
        logger.info("Refresh complete: \(fetched) fetched, \(notModified) not modified (304), \(errors) errors")
    }
}
