import SwiftUI

/// Episode-detail block: spoiler-gated synopsis + inline character cards.
struct EpisodeInsightSection: View {
    let episode: Episode
    @State private var service = EpisodeInsightService.shared

    private var isSupported: Bool {
        service.isSupported(for: episode)
    }

    var body: some View {
        Group {
            if isSupported {
                content
            }
        }
        .task(id: "\(episode.guid)|\(episode.localTranscriptPath ?? "")") {
            service.load(for: episode)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if service.isLoading && service.insight == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading community insight…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let insight = service.insight {
                if insight.hasSynopsis {
                    CommunitySynopsisView(insight: insight)
                }

                if insight.hasCharacters || service.isLoadingCharacters {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Characters")
                            .font(.headline)

                        ForEach(insight.characters) { character in
                            InsightCharacterRow(character: character)
                        }

                        if service.isLoadingCharacters {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(
                                    insight.hasCharacters
                                        ? "Loading more characters…"
                                        : "Loading characters…"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        }
                    }
                }

                if insight.hasSynopsis || insight.hasCharacters {
                    InsightSourceFooter(insight: insight)
                } else if !service.isLoading {
                    Text("The wiki page didn’t include a synopsis or characters for this episode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let message = service.errorMessage, !service.isLoading {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: service.insight?.characters.count)
    }
}
