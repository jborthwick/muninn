import SwiftUI

/// Now Playing panel: community synopsis + spoiler-safe character cards.
struct NowPlayingInsightView: View {
    let episode: Episode

    @State private var service = EpisodeInsightService.shared

    var body: some View {
        Group {
            if !service.isSupported(for: episode) {
                ContentUnavailableView(
                    "Insight unavailable",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("Community insight isn’t mapped for this show yet.")
                )
            } else if service.isLoading && service.insight == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading community insight…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let insight = service.insight {
                insightScroll(insight)
            } else if let message = service.errorMessage {
                ContentUnavailableView(
                    "No insight",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text(message)
                )
            } else {
                ContentUnavailableView(
                    "No insight",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("Nothing found for this episode on the wiki.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: episode.guid) {
            service.load(for: episode)
        }
    }

    private func insightScroll(_ insight: EpisodeInsight) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if insight.hasSynopsis {
                    CommunitySynopsisView(insight: insight)
                }

                if insight.hasCharacters {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Characters")
                            .font(.headline)

                        ForEach(insight.characters) { character in
                            InsightCharacterRow(character: character)
                        }
                    }
                }

                if !insight.hasSynopsis && !insight.hasCharacters {
                    Text("The wiki page didn’t include a synopsis or characters for this episode.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("Spoiler-safe as of this episode · \(insight.attribution)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
