import SwiftUI

/// Compact source footer used under insight lists.
struct InsightSourceFooter: View {
    let insight: EpisodeInsight
    var showAIUnavailableNote: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Spoiler-safe as of this episode")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("Sourced from \(insight.attribution)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let urlString = insight.sourceURL, let url = URL(string: urlString) {
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Link("Episode page", destination: url)
                        .font(.caption2.weight(.semibold))
                }
            }

            if showAIUnavailableNote, !SpoilerSafeBioRewriter.isAvailable {
                Text("Apple Intelligence unavailable — showing short wiki intros")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
