import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let feed = FeedLoader.load(url)
// Patreon feed titles say "NaddPod Patreon Exclusives"; the real show name comes from itunes:author.
let show = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : feed.showTitle
let byID = Dictionary(feed.episodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
let labels = EpisodeLinker.aftershowLabels(in: feed.episodes, showTitle: show)
let links = EpisodeLinker.aftershows(in: feed.episodes, showTitle: show)
let linked = Set(links.map(\.aftershowID))
let candidates = feed.episodes.filter { ep in EpisodeLinker.splitLabel(ep.title).map { labels.contains($0.0.lowercased()) } ?? false }
print("episodes=\(feed.episodes.count) aftershowLabels=\(labels.sorted()) aftershows=\(candidates.count) linked=\(links.count)")
print("by method:", Dictionary(grouping: links, by: \.method.rawValue).mapValues(\.count))
var rng = SystemRandomNumberGenerator()
print("\nsample links:")
for l in links.shuffled(using: &rng).prefix(18) {
    print("  [\(l.method.rawValue)] \(byID[l.aftershowID]!.title.prefix(55))\n        → \(byID[l.episodeID]!.title.prefix(70))")
}
print("\nunlinked aftershows:")
for ep in candidates where !linked.contains(ep.id) { print("  · \(ep.title.prefix(90))") }
// Sanity: an episode with more than one aftershow attached.
let multi = Dictionary(grouping: links, by: \.episodeID).filter { $0.value.count > 1 }
print("\nepisodes with >1 aftershow: \(multi.count)")
for (id, ls) in multi.prefix(6) { print("  \(byID[id]!.title.prefix(60)) ← " + ls.map { String(byID[$0.aftershowID]!.title.prefix(40)) }.joined(separator: " | ")) }
