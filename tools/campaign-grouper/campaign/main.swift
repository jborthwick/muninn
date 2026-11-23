import Foundation
let feed = FeedLoader.load(URL(fileURLWithPath: CommandLine.arguments[1]))
let show = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : feed.showTitle
let links = EpisodeLinker.aftershows(in: feed.episodes, showTitle: show)
let attached = Dictionary(links.map { ($0.aftershowID, $0.episodeID) }, uniquingKeysWith: { a, _ in a })
let groups = CampaignGrouper.group(feed.episodes, showTitle: show, aftershows: attached)
let yf = DateFormatter(); yf.dateFormat = "yyyy-MM"
print("### \(feed.showTitle)  episodes=\(feed.episodes.count)  groups=\(groups.count)  aftershowsAttached=\(attached.count)")
for g in groups {
    let a = g.aftershowIDs.isEmpty ? "" : " +\(g.aftershowIDs.count) aftershows"
    print("  \(g.name) — \(g.episodeIDs.count) eps\(a)  \(yf.string(from: g.firstDate))→\(yf.string(from: g.lastDate))")
    if !g.arcs.isEmpty { print("      arcs: " + g.arcs.map { "\($0.name) (\($0.count))" }.joined(separator: " → ")) }
}
