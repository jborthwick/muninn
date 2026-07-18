import SwiftUI

/// Spoiler-gated community synopsis from a mapped fandom wiki.
struct CommunitySynopsisView: View {
    let insight: EpisodeInsight
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Community synopsis")
                .font(.headline)

            if !isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "Contains spoilers for this episode",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.orange)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded = true
                        }
                    } label: {
                        Text("Show synopsis")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if let synopsis = insight.synopsis {
                        Text(synopsis)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Text(insight.attribution)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let urlString = insight.sourceURL, let url = URL(string: urlString) {
                            Link("Open on Wiki", destination: url)
                                .font(.caption.weight(.semibold))
                        }
                    }

                    Button("Hide synopsis") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded = false
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
