import SwiftUI

/// Character X-ray sheet: spoiler-safe cards from wiki intros.
struct InsightXRayView: View {
    let insight: EpisodeInsight
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if insight.characters.isEmpty {
                    ContentUnavailableView(
                        "No characters found",
                        systemImage: "person.3",
                        description: Text("The wiki page didn’t list characters for this episode.")
                    )
                } else {
                    List(insight.characters) { character in
                        InsightCharacterRow(character: character)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Insight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 2) {
                    Text("Spoiler-safe as of this episode · \(insight.attribution)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if !SpoilerSafeBioRewriter.isAvailable {
                        Text("Apple Intelligence unavailable — showing short wiki intros")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }
}

private struct InsightCharacterRow: View {
    let character: InsightCharacter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(character.name)
                    .font(.headline)
                if let role = character.role {
                    Text(role)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
            }

            Text(character.spoilerSafeBlurb)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let urlString = character.wikiURL, let url = URL(string: urlString) {
                Link("Wiki", destination: url)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }
}
