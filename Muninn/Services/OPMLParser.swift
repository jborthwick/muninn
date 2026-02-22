import Foundation

// MARK: - Data Model

/// A single podcast feed entry extracted from an OPML file.
struct OPMLFeed {
    let title: String
    let feedURL: String
    /// The group/folder name this feed belongs to, if any.
    let groupName: String?
}

// MARK: - Parser

/// Parses OPML (Outline Processor Markup Language) files exported by podcast
/// apps such as Overcast, Pocket Casts, Castro, Apple Podcasts, etc.
///
/// Handles nested outlines: top-level outlines without an `xmlUrl` are treated
/// as folders; child outlines with an `xmlUrl` are treated as feeds.
final class OPMLParser: NSObject, XMLParserDelegate {

    private var feeds: [OPMLFeed] = []
    /// Stack of group names mirrors the outline nesting depth.
    /// `nil` entries represent feed outlines (no name needed once recorded).
    private var groupStack: [String?] = []

    // MARK: - Public API

    /// Parses `data` as OPML and returns all discovered podcast feeds.
    static func parse(_ data: Data) -> [OPMLFeed] {
        let instance = OPMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = instance
        parser.parse()
        return instance.feeds
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.lowercased() == "outline" else { return }

        // xmlUrl attribute (case-insensitive lookup)
        let xmlUrl = attributeDict["xmlUrl"]
            ?? attributeDict["xmlurl"]
            ?? attributeDict["XMLURL"]
            ?? attributeDict["XMLUrl"]
            ?? ""

        let title = attributeDict["text"]
            ?? attributeDict["title"]
            ?? ""

        if !xmlUrl.isEmpty {
            // This outline is a feed — record it under the current innermost group.
            let currentGroup = groupStack.last(where: { $0 != nil }) ?? nil
            feeds.append(OPMLFeed(title: title, feedURL: xmlUrl, groupName: currentGroup))
            // Push a nil so we pop correctly in didEndElement.
            groupStack.append(nil)
        } else {
            // This outline is a group/folder — push its name.
            groupStack.append(title.isEmpty ? nil : title)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName.lowercased() == "outline" else { return }
        if !groupStack.isEmpty {
            groupStack.removeLast()
        }
    }
}
