import Foundation
import SwiftData

@Model
final class ListeningSession {
    var id: UUID = UUID()
    var podcastFeedURL: String
    var podcastTitle: String
    var episodeGUID: String
    var episodeTitle: String
    var startTime: Date
    var duration: TimeInterval // seconds listened
    var date: Date // just the date component for grouping

    init(
        podcastFeedURL: String,
        podcastTitle: String,
        episodeGUID: String,
        episodeTitle: String,
        startTime: Date,
        duration: TimeInterval
    ) {
        self.podcastFeedURL = podcastFeedURL
        self.podcastTitle = podcastTitle
        self.episodeGUID = episodeGUID
        self.episodeTitle = episodeTitle
        self.startTime = startTime
        self.duration = duration

        // Store just the date for easier grouping
        let calendar = Calendar.current
        self.date = calendar.startOfDay(for: startTime)
    }
}

// MARK: - Aggregated Stats (computed, not stored)

struct ListeningStatsOverview {
    var totalMinutes: Int
    var totalEpisodes: Int
    var totalPodcasts: Int
    var streakDays: Int
    var thisWeekMinutes: Int
    var lastWeekMinutes: Int
}

struct PodcastListeningStats: Identifiable {
    var id: String { podcastFeedURL }
    var podcastFeedURL: String
    var podcastTitle: String
    var totalMinutes: Int
    var episodeCount: Int
}

struct DailyListeningStats: Identifiable {
    var id: Date { date }
    var date: Date
    var minutes: Int
}
