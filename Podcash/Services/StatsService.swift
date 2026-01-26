import Foundation
import SwiftData
import os

/// Tracks and computes listening statistics
@Observable
final class StatsService {
    static let shared = StatsService()

    private let logger = AppLogger.stats
    private var modelContext: ModelContext?
    private var currentSessionStart: Date?
    private var currentEpisode: Episode?
    private var accumulatedTime: TimeInterval = 0

    private init() {}

    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }

    // MARK: - Session Tracking

    func startListening(episode: Episode) {
        // Save any previous session first
        endCurrentSession()

        currentEpisode = episode
        currentSessionStart = Date()
        accumulatedTime = 0
    }

    func pauseListening() {
        guard let start = currentSessionStart else { return }
        accumulatedTime += Date().timeIntervalSince(start)
        currentSessionStart = nil

        // Save session on pause if we have meaningful listening time
        saveSessionIfSignificant()
    }

    func resumeListening() {
        guard currentEpisode != nil, currentSessionStart == nil else { return }
        currentSessionStart = Date()
    }

    /// Saves the current session if accumulated time is significant
    private func saveSessionIfSignificant() {
        guard let episode = currentEpisode,
              let context = modelContext,
              accumulatedTime >= 30 else { return }

        let session = ListeningSession(
            podcastFeedURL: episode.podcast?.feedURL ?? "",
            podcastTitle: episode.podcast?.title ?? "Unknown",
            episodeGUID: episode.guid,
            episodeTitle: episode.title,
            startTime: Date(),
            duration: accumulatedTime
        )

        context.insert(session)
        do {
            try context.save()
            logger.info("Saved listening session on pause: \(Int(self.accumulatedTime))s for \(episode.title)")
        } catch {
            logger.error("Failed to save listening session: \(error.localizedDescription)")
        }

        // Reset accumulated time since we saved it
        accumulatedTime = 0
    }

    func endCurrentSession() {
        pauseListening() // Accumulate any remaining time

        guard let episode = currentEpisode,
              let context = modelContext,
              accumulatedTime >= 30 else { // Only track sessions >= 30 seconds
            resetSession()
            return
        }

        let session = ListeningSession(
            podcastFeedURL: episode.podcast?.feedURL ?? "",
            podcastTitle: episode.podcast?.title ?? "Unknown",
            episodeGUID: episode.guid,
            episodeTitle: episode.title,
            startTime: Date(),
            duration: accumulatedTime
        )

        context.insert(session)
        do {
            try context.save()
            logger.info("Saved listening session: \(Int(self.accumulatedTime))s for \(episode.title)")
        } catch {
            logger.error("Failed to save listening session: \(error.localizedDescription)")
        }

        resetSession()
    }

    private func resetSession() {
        currentEpisode = nil
        currentSessionStart = nil
        accumulatedTime = 0
    }

    // MARK: - Stats Computation

    func getOverview(context: ModelContext) -> ListeningStatsOverview {
        let allSessions = fetchAllSessions(context: context)

        let totalSeconds = allSessions.reduce(0) { $0 + $1.duration }
        let uniqueEpisodes = Set(allSessions.map { $0.episodeGUID }).count
        let uniquePodcasts = Set(allSessions.map { $0.podcastFeedURL }).count

        // Calculate streak
        let streakDays = calculateStreak(sessions: allSessions)

        // This week vs last week
        let calendar = Calendar.current
        let now = Date()
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        let startOfLastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: startOfWeek)!

        let thisWeekSeconds = allSessions
            .filter { $0.date >= startOfWeek }
            .reduce(0) { $0 + $1.duration }

        let lastWeekSeconds = allSessions
            .filter { $0.date >= startOfLastWeek && $0.date < startOfWeek }
            .reduce(0) { $0 + $1.duration }

        return ListeningStatsOverview(
            totalMinutes: Int(totalSeconds / 60),
            totalEpisodes: uniqueEpisodes,
            totalPodcasts: uniquePodcasts,
            streakDays: streakDays,
            thisWeekMinutes: Int(thisWeekSeconds / 60),
            lastWeekMinutes: Int(lastWeekSeconds / 60)
        )
    }

    func getPodcastStats(context: ModelContext) -> [PodcastListeningStats] {
        let allSessions = fetchAllSessions(context: context)

        // Group by podcast
        var podcastData: [String: (title: String, seconds: TimeInterval, episodes: Set<String>)] = [:]

        for session in allSessions {
            let url = session.podcastFeedURL
            if var data = podcastData[url] {
                data.seconds += session.duration
                data.episodes.insert(session.episodeGUID)
                podcastData[url] = data
            } else {
                podcastData[url] = (session.podcastTitle, session.duration, [session.episodeGUID])
            }
        }

        return podcastData.map { url, data in
            PodcastListeningStats(
                podcastFeedURL: url,
                podcastTitle: data.title,
                totalMinutes: Int(data.seconds / 60),
                episodeCount: data.episodes.count
            )
        }
        .sorted { $0.totalMinutes > $1.totalMinutes }
    }

    func getDailyStats(context: ModelContext, days: Int = 30) -> [DailyListeningStats] {
        let allSessions = fetchAllSessions(context: context)
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -days, to: Date())!

        // Group by date
        var dailyData: [Date: TimeInterval] = [:]

        for session in allSessions where session.date >= cutoff {
            dailyData[session.date, default: 0] += session.duration
        }

        // Fill in missing days with zeros
        var result: [DailyListeningStats] = []
        var date = calendar.startOfDay(for: cutoff)
        let today = calendar.startOfDay(for: Date())

        while date <= today {
            let minutes = Int((dailyData[date] ?? 0) / 60)
            result.append(DailyListeningStats(date: date, minutes: minutes))
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }

        return result
    }

    private func fetchAllSessions(context: ModelContext) -> [ListeningSession] {
        let descriptor = FetchDescriptor<ListeningSession>(
            sortBy: [SortDescriptor(\.startTime, order: .reverse)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch listening sessions: \(error.localizedDescription)")
            return []
        }
    }

    private func calculateStreak(sessions: [ListeningSession]) -> Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Get unique listening dates
        let listeningDates = Set(sessions.map { $0.date }).sorted(by: >)

        guard !listeningDates.isEmpty else { return 0 }

        // Check if listened today or yesterday (streak can continue)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        guard listeningDates.first == today || listeningDates.first == yesterday else {
            return 0
        }

        // Count consecutive days
        var streak = 0
        var checkDate = listeningDates.first!

        for date in listeningDates {
            if date == checkDate {
                streak += 1
                checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
            } else if date < checkDate {
                break
            }
        }

        return streak
    }
}
