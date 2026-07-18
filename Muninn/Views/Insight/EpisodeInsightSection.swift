import SwiftUI

/// Episode-detail block: loading, synopsis disclosure, and Insight entry.
struct EpisodeInsightSection: View {
    let episode: Episode
    @State private var service = EpisodeInsightService.shared
    @State private var showXRay = false

    private var isSupported: Bool {
        service.isSupported(for: episode)
    }

    var body: some View {
        Group {
            if isSupported {
                content
            }
        }
        .task(id: episode.guid) {
            service.load(for: episode)
        }
        .onDisappear {
            // Keep cache; only cancel in-flight work for this screen.
            service.cancel()
        }
        .sheet(isPresented: $showXRay) {
            if let insight = service.insight {
                InsightXRayView(insight: insight)
            }
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

                if insight.hasCharacters {
                    Button {
                        showXRay = true
                    } label: {
                        HStack {
                            Image(systemName: "sparkles.rectangle.stack")
                            Text("Insight")
                            Text("· \(insight.characters.count) characters")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(12)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            } else if let message = service.errorMessage, !service.isLoading {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
