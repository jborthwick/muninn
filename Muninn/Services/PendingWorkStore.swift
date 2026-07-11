import Foundation

/// Persists transcription/chapter queue GUIDs so work can resume after the app is suspended or terminated.
enum PendingWorkStore {
    private static let transcriptionKey = "pendingTranscriptionGUIDs"
    private static let chapterKey = "pendingChapterGUIDs"

    static var transcriptionGUIDs: [String] {
        UserDefaults.standard.stringArray(forKey: transcriptionKey) ?? []
    }

    static var chapterGUIDs: [String] {
        UserDefaults.standard.stringArray(forKey: chapterKey) ?? []
    }

    static func addTranscription(guid: String) {
        var guids = transcriptionGUIDs
        guard !guids.contains(guid) else { return }
        guids.append(guid)
        UserDefaults.standard.set(guids, forKey: transcriptionKey)
    }

    static func removeTranscription(guid: String) {
        var guids = transcriptionGUIDs
        guids.removeAll { $0 == guid }
        UserDefaults.standard.set(guids, forKey: transcriptionKey)
    }

    static func addChapter(guid: String) {
        var guids = chapterGUIDs
        guard !guids.contains(guid) else { return }
        guids.append(guid)
        UserDefaults.standard.set(guids, forKey: chapterKey)
    }

    static func removeChapter(guid: String) {
        var guids = chapterGUIDs
        guids.removeAll { $0 == guid }
        UserDefaults.standard.set(guids, forKey: chapterKey)
    }

    static var hasPendingWork: Bool {
        !transcriptionGUIDs.isEmpty || !chapterGUIDs.isEmpty
    }
}
