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
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(insight.characters) { character in
                                InsightCharacterRow(character: character)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
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
                InsightAttributionFooter(insight: insight)
            }
        }
    }
}

/// Compact list card: portrait + name + short blurb. Tap for full detail.
struct InsightCharacterRow: View {
    let character: InsightCharacter
    @State private var showDetail = false

    private let artSize: CGFloat = 56

    var body: some View {
        Button {
            showDetail = true
        } label: {
            HStack(alignment: .center, spacing: 12) {
                artwork

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(character.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let role = character.role {
                            Text(role)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Spacer(minLength: 0)
                    }

                    Text(character.spoilerSafeBlurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .sheet(isPresented: $showDetail) {
            InsightCharacterDetailView(character: character)
        }
        .accessibilityHint("Shows full character details")
    }

    private var artwork: some View {
        let artURL = character.artworkURL.flatMap(URL.init(string:))
        return CachedAsyncImage(url: artURL) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: artURL == nil ? "person.fill" : "photo")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: artSize, height: artSize)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct InsightAttributionFooter: View {
    let insight: EpisodeInsight

    var body: some View {
        InsightSourceFooter(insight: insight, showAIUnavailableNote: true)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(.bar)
    }
}
