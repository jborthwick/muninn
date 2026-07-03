import Foundation

/// Parses chapter timestamps from RSS episode descriptions / show notes.
enum ChapterShowNotesParser {
    /// Returns chapters when 3+ `H:MM:SS - Title` (or similar) markers are found.
    static func chapters(from description: String?, duration: TimeInterval) -> [Chapter]? {
        guard let description, !description.isEmpty else { return nil }

        let text = description.htmlTagsStripped
        var parsed: [(start: TimeInterval, title: String)] = []

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let match = parseLine(trimmed) else { continue }
            parsed.append(match)
        }

        guard parsed.count >= 3 else { return nil }

        parsed.sort { $0.start < $1.start }

        // De-duplicate identical start times; keep the longer title.
        var unique: [(start: TimeInterval, title: String)] = []
        for item in parsed {
            if let last = unique.last, abs(last.start - item.start) < 1 {
                if item.title.count > last.title.count { unique[unique.count - 1] = item }
            } else {
                unique.append(item)
            }
        }

        guard unique.count >= 3 else { return nil }

        let effectiveDuration = max(duration, unique.last!.start + 60)
        return unique.enumerated().map { index, item in
            let end = index + 1 < unique.count ? unique[index + 1].start : effectiveDuration
            return Chapter(startTime: item.start, endTime: end, title: item.title)
        }
    }

    /// First ~400 characters of plain-text description for LLM context.
    static func synopsis(from description: String?) -> String? {
        guard let description else { return nil }
        let plain = description.htmlTagsStripped
        guard !plain.isEmpty else { return nil }
        let clipped = String(plain.prefix(400))
        return clipped.count < plain.count ? clipped + "…" : clipped
    }

    // MARK: - Line parsing

    private static func parseLine(_ line: String) -> (start: TimeInterval, title: String)? {
        // Optional wrapper: (1:23:45) Title
        let working = line
        if working.hasPrefix("("), let close = working.firstIndex(of: ")") {
            let inner = working[working.index(after: working.startIndex)..<close]
            if let time = parseTimestamp(String(inner)) {
                let rest = working[working.index(after: close)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-–—:"))
                    .trimmingCharacters(in: .whitespaces)
                guard !rest.isEmpty else { return nil }
                return (time, rest)
            }
        }

        // 1:23:45 - Title / 12:34 Title / 1:23:45 — Title
        guard let regex = lineRegex else { return nil }
        let ns = working as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: working, range: range),
              match.numberOfRanges >= 3 else { return nil }

        let timeStr = ns.substring(with: match.range(at: 1))
        var title = ns.substring(with: match.range(at: 2))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—:"))
            .trimmingCharacters(in: .whitespaces)
        guard let time = parseTimestamp(timeStr), !title.isEmpty else { return nil }

        // Strip leading/trailing quotes
        if (title.hasPrefix("\"") && title.hasSuffix("\"")) || (title.hasPrefix("'") && title.hasSuffix("'")) {
            title = String(title.dropFirst().dropLast())
        }
        return (time, title)
    }

    private static let lineRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^(\d{1,2}:\d{2}(?::\d{2})?)\s*[-–—:]?\s*(.+)$"#)
    }()

    private static func parseTimestamp(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }
}
