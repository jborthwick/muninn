import Foundation
import SwiftData

@Model
final class QueueItem {
    var episode: Episode?
    var sortOrder: Int = 0
    var dateAdded: Date = Date()

    init(episode: Episode, sortOrder: Int = 0) {
        self.episode = episode
        self.sortOrder = sortOrder
    }
}
