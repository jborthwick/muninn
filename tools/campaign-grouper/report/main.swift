import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let only = CommandLine.arguments.dropFirst(2)
let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".xml") }.sorted()
let yf = DateFormatter(); yf.dateFormat = "yyyy-MM"
for f in files where only.isEmpty || only.contains(String(f.dropLast(4))) {
    let feed = FeedLoader.load(dir.appendingPathComponent(f))
    let titles = Dictionary(feed.episodes.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
    let groups = CampaignGrouper.group(feed.episodes, showTitle: feed.showTitle)
    let named = groups.filter { $0.source == .title }.reduce(0) { $0 + $1.episodeIDs.count }
    let unsorted = groups.filter { $0.source == .unsorted }.reduce(0) { $0 + $1.episodeIDs.count }
    print("\n### \(feed.showTitle)  episodes=\(feed.episodes.count) groups=\(groups.count) namedFromTitles=\(named) unsorted=\(unsorted)")
    for g in groups {
        let first = titles[g.episodeIDs.first!] ?? ""
        let last = titles[g.episodeIDs.last!] ?? ""
        print(String(format: "  %-28@ %-8@ %4d  %@→%@", g.name as NSString, g.source.rawValue as NSString, g.episodeIDs.count,
                     yf.string(from: g.firstDate) as NSString, yf.string(from: g.lastDate) as NSString))
        if g.source == .unsorted {
            for id in g.episodeIDs.prefix(12) { print("      · \(titles[id]!.prefix(80))") }
        }
    }
}
