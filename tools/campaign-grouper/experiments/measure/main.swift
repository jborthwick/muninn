import Foundation
import FoundationModels
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let model = SystemLanguageModel.default
print("contextSize:", model.contextSize)
for f in try FileManager.default.contentsOfDirectory(atPath: dir.path).filter({ $0.hasSuffix(".xml") }).sorted() {
    let feed = FeedLoader.load(dir.appendingPathComponent(f))
    // Minimal input a whole-feed sort would need: one line per episode with index, season, type, title.
    let lines = feed.episodes.enumerated().map { i, e in "\(i)|\(e.season.map(String.init) ?? "")|\(e.episodeType ?? "")|\(e.title)" }
    let t = try await model.tokenCount(for: lines.joined(separator: "\n"))
    // Output would need at least one (index → group) pair per episode.
    let out = try await model.tokenCount(for: feed.episodes.indices.map { "{\"i\":\($0),\"g\":3}" }.joined(separator: ","))
    print(String(format: "%-26@ eps=%4d  inputTokens=%6d  minOutputTokens=%6d  total≈%6d", f as NSString, feed.episodes.count, t, out, t + out))
}
