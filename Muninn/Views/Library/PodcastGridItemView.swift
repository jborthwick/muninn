import SwiftUI

struct PodcastGridItemView: View {
    let podcast: Podcast

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: URL(string: podcast.artworkURL ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                artworkPlaceholder
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(podcast.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.2))
            .overlay {
                Image(systemName: "mic")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
    }
}

#Preview {
    let podcast = Podcast(
        feedURL: "https://example.com/feed.xml",
        title: "Sample Podcast With A Long Title",
        author: "John Doe",
        artworkURL: nil
    )
    return PodcastGridItemView(podcast: podcast)
        .frame(width: 110)
        .padding()
}
