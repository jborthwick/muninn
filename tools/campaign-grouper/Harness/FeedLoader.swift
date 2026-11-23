import Foundation

// Script-only: minimal RSS loader (non-namespace-aware XMLParser, matching on qualified names).
final class FeedLoader: NSObject, XMLParserDelegate {
    var showTitle = ""
    var episodes: [GroupableEpisode] = []
    private var inItem = false
    private var text = ""
    private var cur: [String: String] = [:]
    private static let df: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"; return f
    }()

    static func load(_ url: URL) -> FeedLoader {
        let l = FeedLoader()
        let p = XMLParser(contentsOf: url)!
        p.delegate = l; p.parse()
        return l
    }
    func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
        if e == "item" { inItem = true; cur = [:] }
        text = ""
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ p: XMLParser, foundCDATA d: Data) { text += String(decoding: d, as: UTF8.self) }
    func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch e {
            case "title", "guid", "pubDate", "itunes:season", "itunes:episodeType": if cur[e] == nil { cur[e] = t }
            case "item":
                inItem = false
                let date = cur["pubDate"].flatMap { Self.df.date(from: $0) } ?? .distantPast
                episodes.append(GroupableEpisode(
                    id: cur["guid"] ?? UUID().uuidString, title: cur["title"] ?? "",
                    season: cur["itunes:season"].flatMap(Int.init), episodeType: cur["itunes:episodeType"], pubDate: date))
            default: break
            }
        } else if e == "title", showTitle.isEmpty { showTitle = t }
        text = ""
    }
}

