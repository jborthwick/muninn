import SwiftUI

struct PodcastRowView: View {
    let podcast: Podcast

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: URL(string: podcast.artworkURL ?? "")) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                artworkPlaceholder
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(podcast.title)
                    .font(.headline)
                    .lineLimit(2)

                if let author = podcast.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("\(podcast.episodes.count) episodes")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }

    private var artworkPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.2))
            .overlay {
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
            }
    }
}

#Preview {
    let podcast = Podcast(
        feedURL: "https://example.com/feed.xml",
        title: "Sample Podcast",
        author: "John Doe",
        artworkURL: nil
    )
    return PodcastRowView(podcast: podcast)
        .padding()
}
