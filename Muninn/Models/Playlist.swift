import Foundation
import SwiftData

@Model
final class Playlist {
    var id: UUID = UUID()
    var name: String
    var colorHex: String?
    var sortOrder: Int = 0
    var dateCreated: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \PlaylistItem.playlist)
    var items: [PlaylistItem] = []

    init(name: String, colorHex: String? = nil) {
        self.name = name
        self.colorHex = colorHex
    }
}
