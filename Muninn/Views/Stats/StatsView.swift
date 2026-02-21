import SwiftUI
import SwiftData

struct StatsView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            List {
                // Overview section
                Section {
                    let overview = StatsService.shared.getOverview(context: modelContext)

                    StatsCard(
                        title: "Total Listening",
                        value: formatMinutes(overview.totalMinutes),
                        icon: "headphones",
                        color: .blue
                    )

                    HStack(spacing: 16) {
                        MiniStatView(
                            title: "Episodes",
                            value: "\(overview.totalEpisodes)",
                            icon: "play.circle"
                        )

                        MiniStatView(
                            title: "Podcasts",
                            value: "\(overview.totalPodcasts)",
                            icon: "mic"
                        )

                        MiniStatView(
                            title: "Streak",
                            value: "\(overview.streakDays) days",
                            icon: "flame"
                        )
                    }
                    .padding(.vertical, 8)
                }

                // This week vs last week
                Section("Weekly Comparison") {
                    let overview = StatsService.shared.getOverview(context: modelContext)
                    let change = overview.thisWeekMinutes - overview.lastWeekMinutes
                    let changePercent = overview.lastWeekMinutes > 0
                        ? Double(change) / Double(overview.lastWeekMinutes) * 100
                        : 0

                    HStack {
                        VStack(alignment: .leading) {
                            Text("This Week")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(formatMinutes(overview.thisWeekMinutes))
                                .font(.title2)
                                .fontWeight(.semibold)
                        }

                        Spacer()

                        VStack(alignment: .trailing) {
                            Text("Last Week")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(formatMinutes(overview.lastWeekMinutes))
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if overview.lastWeekMinutes > 0 {
                        HStack {
                            Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .foregroundStyle(change >= 0 ? .green : .orange)
                            Text("\(abs(Int(changePercent)))% \(change >= 0 ? "more" : "less") than last week")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Top podcasts
                Section("Top Podcasts") {
                    let podcastStats = StatsService.shared.getPodcastStats(context: modelContext)

                    if podcastStats.isEmpty {
                        Text("No listening data yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(podcastStats.prefix(5)) { stat in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(stat.podcastTitle)
                                        .lineLimit(1)
                                    Text("\(stat.episodeCount) episodes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(formatMinutes(stat.totalMinutes))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Daily activity (last 7 days)
                Section("Last 7 Days") {
                    let dailyStats = StatsService.shared.getDailyStats(context: modelContext, days: 7)

                    if dailyStats.allSatisfy({ $0.minutes == 0 }) {
                        Text("No listening data yet")
                            .foregroundStyle(.secondary)
                    } else {
                        DailyBarChart(stats: dailyStats)
                            .frame(height: 120)
                            .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Listening Stats")
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes) min"
        } else {
            let hours = minutes / 60
            let mins = minutes % 60
            if mins == 0 {
                return "\(hours) hr"
            }
            return "\(hours) hr \(mins) min"
        }
    }
}

// MARK: - Stats Card

private struct StatsCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(color)
                .frame(width: 44)

            VStack(alignment: .leading) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title)
                    .fontWeight(.bold)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Mini Stat View

private struct MiniStatView: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Daily Bar Chart

private struct DailyBarChart: View {
    let stats: [DailyListeningStats]

    private var maxMinutes: Int {
        stats.map { $0.minutes }.max() ?? 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(stats) { stat in
                VStack {
                    Spacer()

                    RoundedRectangle(cornerRadius: 4)
                        .fill(stat.minutes > 0 ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(
                            height: stat.minutes > 0
                                ? max(CGFloat(stat.minutes) / CGFloat(maxMinutes) * 80, 4)
                                : 4
                        )

                    Text(dayLabel(stat.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
}

#Preview {
    StatsView()
        .modelContainer(for: ListeningSession.self, inMemory: true)
}
