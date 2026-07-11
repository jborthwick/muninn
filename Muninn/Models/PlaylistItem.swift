import Foundation
import SwiftData

@Model
final class PlaylistItem {
    var episode: Episode?
    var sortOrder: Int = 0
    var dateAdded: Date = Date()
    var playlist: Playlist?

    init(episode: Episode, sortOrder: Int = 0) {
        self.episode = episode
        self.sortOrder = sortOrder
    }
}
