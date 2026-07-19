import SwiftUI

/// Full character X-ray: large portrait, facts, and spoiler-safe bio.
struct InsightCharacterDetailView: View {
    let character: InsightCharacter
    @Environment(\.dismiss) private var dismiss

    private let heroHeight: CGFloat = 260

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroArtwork

                    if character.hasArtworkCredit {
                        artworkCreditLabel
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(character.name)
                                .font(.title2.weight(.bold))
                            if let role = character.role {
                                Text(role)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            Spacer(minLength: 0)
                        }

                        if character.hasFacts, let facts = character.facts {
                            factStrip(facts)
                        }
                    }

                    Text(character.spoilerSafeBlurb)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        if let urlString = character.wikiURL, let url = URL(string: urlString) {
                            Link(destination: url) {
                                Label("Open wiki page", systemImage: "safari")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }

                        Text("Character info adapted from the community wiki. Artwork remains the property of its creator.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Character")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var heroArtwork: some View {
        let artURL = character.artworkURL.flatMap(URL.init(string:))
        return CachedAsyncImage(url: artURL) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: artURL == nil ? "person.fill" : "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artworkCreditLabel: some View {
        if let credit = character.artworkCredit {
            let creditURL = character.artworkCreditURL.flatMap(URL.init(string:))
            HStack(spacing: 4) {
                Text("Art by")
                    .foregroundStyle(.secondary)
                if let creditURL {
                    Link(credit, destination: creditURL)
                } else {
                    Text(credit)
                        .foregroundStyle(.primary)
                }
            }
            .font(.caption.weight(.medium))
        }
    }

    private func factStrip(_ facts: [InsightCharacterFact]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.label.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.4)
                    Text(fact.value)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

/// Simple wrapping layout for X-ray fact chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let result = arrange(maxWidth: maxWidth, subviews: subviews)
        return result.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = arrange(maxWidth: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widthUsed: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            widthUsed = max(widthUsed, x - spacing)
        }

        return (
            CGSize(width: maxWidth.isFinite ? maxWidth : widthUsed, height: y + rowHeight),
            frames
        )
    }
}
