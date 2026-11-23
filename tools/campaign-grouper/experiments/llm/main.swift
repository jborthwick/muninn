import Foundation
import FoundationModels

// One model call per show: label each deterministic group, place leftover episodes.

@Generable
enum GroupKind: String {
    case campaign      // long-running story actual play
    case miniSeries    // short story arc or mini-campaign
    case oneShots      // collection of one-shot games
    case talkShow      // discussion, Q&A, advice, news, aftershow, community updates
}

@Generable
struct GroupLabel {
    @Guide(description: "The group id exactly as given, like G3")
    var id: String
    var kind: GroupKind
}

@Generable
struct LeftoverPlacement {
    @Guide(description: "The leftover id exactly as given, like L2")
    var id: String
    @Guide(description: "Id of the group it belongs to, like G3, or NONE")
    var groupID: String
}

@Generable
struct ShowOrganization {
    var groups: [GroupLabel]
    var leftovers: [LeftoverPlacement]
}

let instructions = """
You organize episodes of a tabletop roleplaying game podcast. You get groups of episodes \
(with a few example titles) and some leftover episode titles. Label every group's kind. \
For each leftover, give the id of the group it clearly belongs to, or NONE if unsure.
"""

func prompt(groups: [Campaign], leftovers: [String], titles: [String: String]) -> String {
    var lines = ["Groups:"]
    for (i, g) in groups.enumerated() {
        let ids = g.episodeIDs
        let samples = [ids.first, ids.count > 2 ? ids[ids.count / 2] : nil, ids.last].compactMap { $0 }
        let ex = Array(NSOrderedSet(array: samples.compactMap { titles[$0].map { String($0.prefix(70)) } })) as! [String]
        lines.append("G\(i + 1): \(g.name) (\(ids.count) episodes) e.g. " + ex.map { "\"\($0)\"" }.joined(separator: "; "))
    }
    lines.append("\nLeftovers:")
    for (i, t) in leftovers.enumerated() { lines.append("L\(i + 1): \(t.prefix(80))") }
    return lines.joined(separator: "\n")
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let only = Set(CommandLine.arguments.dropFirst(2))
let model = SystemLanguageModel.default
let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".xml") }.sorted()

for f in files where only.isEmpty || only.contains(String(f.dropLast(4))) {
    let feed = FeedLoader.load(dir.appendingPathComponent(f))
    let titles = Dictionary(feed.episodes.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
    let all = CampaignGrouper.group(feed.episodes, showTitle: feed.showTitle)
    let groups = all.filter { $0.source == .title || $0.source == .season }
    let leftoverIDs = all.filter { $0.source == .unsorted }.flatMap(\.episodeIDs).prefix(40)
    let leftovers = leftoverIDs.map { titles[$0] ?? "" }
    let p = prompt(groups: groups, leftovers: Array(leftovers), titles: titles)

    let session = LanguageModelSession(instructions: instructions)
    let tokens = try await model.tokenCount(for: p)
    let start = Date()
    print("\n### \(feed.showTitle)  groups=\(groups.count) leftovers=\(leftovers.count) promptTokens=\(tokens)")
    do {
        let r = try await session.respond(to: p, generating: ShowOrganization.self,
                                          options: GenerationOptions(temperature: 0))
        let secs = Date().timeIntervalSince(start)
        print(String(format: "  (%.1fs)", secs))
        let kinds = Dictionary(r.content.groups.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        for (i, g) in groups.enumerated() {
            print(String(format: "  G%-3d %-34@ %4d  %@", i + 1, g.name as NSString, g.episodeIDs.count,
                         (kinds["G\(i + 1)"].map { "\($0)" } ?? "MISSING") as NSString))
        }
        for pl in r.content.leftovers {
            guard let n = Int(pl.id.dropFirst()), n >= 1, n <= leftovers.count else { print("  bad leftover id \(pl.id)"); continue }
            let target = Int(pl.groupID.dropFirst()).flatMap { $0 >= 1 && $0 <= groups.count ? groups[$0 - 1].name : nil } ?? "NONE"
            print("    L\(n) \(leftovers[n - 1].prefix(60)) → \(target)")
        }
    } catch {
        print("  ERROR: \(error)")
    }
}
