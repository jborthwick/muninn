import Foundation

/// Disk cache for per-episode insight JSON under Documents/Insight/.
enum EpisodeInsightStore {
    private static let folderName = "Insight"

    static func directoryURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documents.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(forEpisodeGUID guid: String) -> URL {
        let safe = guid
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directoryURL().appendingPathComponent("\(safe).json")
    }

    static func load(guid: String) -> EpisodeInsight? {
        let url = fileURL(forEpisodeGUID: guid)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let insight = try? JSONDecoder().decode(EpisodeInsight.self, from: data) else {
            return nil
        }
        guard insight.isCurrentCache else {
            remove(guid: guid)
            return nil
        }
        return insight
    }

    static func save(_ insight: EpisodeInsight, guid: String) {
        let url = fileURL(forEpisodeGUID: guid)
        guard let data = try? JSONEncoder().encode(insight) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func remove(guid: String) {
        let url = fileURL(forEpisodeGUID: guid)
        try? FileManager.default.removeItem(at: url)
    }

    static func filename(for guid: String) -> String {
        fileURL(forEpisodeGUID: guid).lastPathComponent
    }
}
