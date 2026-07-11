import Foundation

enum PlaylistSortMode: String, CaseIterable {
    case playlist
    case newest
    case oldest

    var label: String {
        switch self {
        case .playlist: return "Playlist"
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        }
    }

    var icon: String {
        switch self {
        case .playlist: return "list.number"
        case .newest, .oldest: return "arrow.up.arrow.down"
        }
    }

    mutating func cycle() {
        switch self {
        case .playlist: self = .newest
        case .newest: self = .oldest
        case .oldest: self = .playlist
        }
    }
}

enum PlaylistDetailFilters {
    static func items(
        from items: [PlaylistItem],
        searchText: String,
        sortMode: PlaylistSortMode,
        downloadedOnly: Bool,
        unplayedOnly: Bool
    ) -> [PlaylistItem] {
        var result = items

        if downloadedOnly {
            result = result.filter { $0.episode?.localFilePath != nil }
        }
        if unplayedOnly {
            result = result.filter { ($0.episode?.isPlayed ?? false) == false }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.episode?.title.lowercased().contains(query) ?? false }
        }

        switch sortMode {
        case .playlist:
            break
        case .newest:
            result.sort {
                ($0.episode?.publishedDate ?? .distantPast) > ($1.episode?.publishedDate ?? .distantPast)
            }
        case .oldest:
            result.sort {
                ($0.episode?.publishedDate ?? .distantPast) < ($1.episode?.publishedDate ?? .distantPast)
            }
        }

        return result
    }
}
