import Foundation

struct Chapter: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var startTime: TimeInterval
    var endTime: TimeInterval   // next chapter's startTime, or episode duration
    var title: String
}
