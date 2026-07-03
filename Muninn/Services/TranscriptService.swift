import Foundation
import Observation

@MainActor
@Observable
final class TranscriptService {
    static let shared = TranscriptService()
    private init() {}

    private(set) var segments: [TranscriptSegment] = []
    private(set) var isLoading = false
    private(set) var error: String?

    // In-memory cache keyed by transcript URL string
    private var cache: [String: [TranscriptSegment]] = [:]

    // MARK: - Public API

    func load(for episode: Episode) async {
        // Tier 1: locally-generated transcript on disk (from on-device transcription)
        if let localURL = episode.localTranscriptURL,
           FileManager.default.fileExists(atPath: localURL.path),
           let data = try? Data(contentsOf: localURL) {
            let parsed = parsePodcastIndexJSON(data)
            if !parsed.isEmpty {
                segments = parsed
                error = nil
                isLoading = false
                return
            }
        }

        // Tier 2: RSS-provided transcript URL
        guard let urlString = episode.transcriptURL, let url = URL(string: urlString) else {
            segments = []
            error = nil
            return
        }

        // Return cached result immediately
        if let cached = cache[urlString] {
            segments = cached
            error = nil
            return
        }

        isLoading = true
        error = nil
        segments = []

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let mimeType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let parsed = parse(data: data, url: url, mimeType: mimeType)
            cache[urlString] = parsed
            segments = parsed
        } catch {
            self.error = "Could not load transcript: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func clear() {
        segments = []
        error = nil
        isLoading = false
    }

    // MARK: - Format Detection & Dispatch

    private func parse(data: Data, url: URL, mimeType: String) -> [TranscriptSegment] {
        let ext = url.pathExtension.lowercased()
        if ext == "vtt" || mimeType.contains("vtt") {
            return parseVTT(data)
        }
        if ext == "json" || mimeType.contains("json") {
            return parsePodcastIndexJSON(data)
        }
        if ext == "srt" {
            return parseSRT(data)
        }
        // Fallback: try VTT first, then JSON
        let vtt = parseVTT(data)
        if !vtt.isEmpty { return vtt }
        return parsePodcastIndexJSON(data)
    }

    // MARK: - VTT Parser

    private func parseVTT(_ data: Data) -> [TranscriptSegment] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var segments: [TranscriptSegment] = []
        let lines = text.components(separatedBy: .newlines)
        var i = 0

        // Skip WEBVTT header line
        if lines.first?.hasPrefix("WEBVTT") == true { i = 1 }

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            // Skip NOTE blocks, STYLE blocks, REGION blocks, and blank lines
            if line.isEmpty || line.hasPrefix("NOTE") || line.hasPrefix("STYLE") || line.hasPrefix("REGION") {
                i += 1
                continue
            }

            // Detect timestamp line: "HH:MM:SS.mmm --> HH:MM:SS.mmm" or "MM:SS.mmm --> MM:SS.mmm"
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                guard parts.count >= 2,
                      let start = parseVTTTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
                      let end = parseVTTTimestamp(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") else {
                    i += 1
                    continue
                }

                // Collect cue text lines until empty line
                i += 1
                var cueLines: [String] = []
                var speaker: String?

                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    var cueLine = lines[i]
                    // Strip VTT voice cue tags like <v Speaker Name>text</v>
                    if cueLine.hasPrefix("<v "), let closeAngle = cueLine.firstIndex(of: ">") {
                        let speakerRange = cueLine.index(cueLine.startIndex, offsetBy: 3)..<closeAngle
                        speaker = String(cueLine[speakerRange])
                        cueLine = String(cueLine[cueLine.index(after: closeAngle)...])
                        // Remove closing </v> if present
                        cueLine = cueLine.replacingOccurrences(of: "</v>", with: "")
                    }
                    // Strip other HTML-like tags (<c>, <b>, <i>, timestamps like <00:01.000>)
                    cueLine = stripVTTTags(cueLine)
                    if !cueLine.trimmingCharacters(in: .whitespaces).isEmpty {
                        cueLines.append(cueLine.trimmingCharacters(in: .whitespaces))
                    }
                    i += 1
                }

                let text = cueLines.joined(separator: " ")
                if !text.isEmpty {
                    let wordSegments = parseVTTInlineWords(
                        text: text,
                        cueStart: start,
                        cueEnd: end,
                        speaker: speaker
                    )
                    segments.append(contentsOf: wordSegments)
                }
                continue
            }

            // Skip cue identifiers (numeric or arbitrary labels before timestamp lines)
            i += 1
        }

        return segments
    }

    private func parseVTTTimestamp(_ s: String) -> TimeInterval? {
        // Supports HH:MM:SS.mmm and MM:SS.mmm
        let parts = s.components(separatedBy: ":")
        if parts.count == 3,
           let h = Double(parts[0]),
           let m = Double(parts[1]),
           let sec = Double(parts[2]) {
            return h * 3600 + m * 60 + sec
        }
        if parts.count == 2,
           let m = Double(parts[0]),
           let sec = Double(parts[1]) {
            return m * 60 + sec
        }
        return nil
    }

    private func stripVTTTags(_ s: String) -> String {
        // Remove <tag> and </tag> and timestamp tags like <00:01.000>
        var result = s
        while let open = result.range(of: "<"), let close = result.range(of: ">", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound...close.lowerBound)
        }
        return result
    }

    // MARK: - VTT Inline Word Timestamps

    /// Splits cue text on WebVTT inline timestamp tags (`<00:01.234>`) into word-level segments.
    /// Falls back to a single segment when no inline tags are present.
    private func parseVTTInlineWords(
        text: String,
        cueStart: TimeInterval,
        cueEnd: TimeInterval,
        speaker: String?
    ) -> [TranscriptSegment] {
        guard let regex = Self.inlineTimestampRegex else {
            let cleaned = stripVTTTags(text).trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { return [] }
            return [TranscriptSegment(startTime: cueStart, endTime: cueEnd, text: cleaned, speaker: speaker)]
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else {
            let cleaned = stripVTTTags(text).trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { return [] }
            return [TranscriptSegment(startTime: cueStart, endTime: cueEnd, text: cleaned, speaker: speaker)]
        }

        var segments: [TranscriptSegment] = []
        var priorEnd = cueStart

        // Text before the first inline tag shares the cue start time.
        let firstTagLoc = matches[0].range.location
        if firstTagLoc > 0 {
            let prefix = stripVTTTags(nsText.substring(with: NSRange(location: 0, length: firstTagLoc)))
                .trimmingCharacters(in: .whitespaces)
            let prefixWords = prefix.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if !prefixWords.isEmpty {
                let slot = (cueEnd - cueStart) / Double(prefixWords.count)
                for word in prefixWords {
                    let start = priorEnd
                    let end = min(start + slot, cueEnd)
                    segments.append(TranscriptSegment(startTime: start, endTime: end, text: word, speaker: speaker))
                    priorEnd = end
                }
            }
        }

        for (index, match) in matches.enumerated() {
            guard let wordStart = parseInlineVTTTimestamp(match, in: nsText) else { continue }

            let textStart = match.range.location + match.range.length
            let textEnd = index + 1 < matches.count ? matches[index + 1].range.location : nsText.length
            guard textEnd > textStart else { continue }

            let rawWord = nsText.substring(with: NSRange(location: textStart, length: textEnd - textStart))
            let word = stripVTTTags(rawWord).trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }

            let wordEnd: TimeInterval
            if index + 1 < matches.count, let nextStart = parseInlineVTTTimestamp(matches[index + 1], in: nsText) {
                wordEnd = nextStart
            } else {
                wordEnd = cueEnd
            }

            segments.append(TranscriptSegment(
                startTime: wordStart,
                endTime: max(wordEnd, wordStart + 0.05),
                text: word,
                speaker: speaker
            ))
        }

        if segments.isEmpty {
            let cleaned = stripVTTTags(text).trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { return [] }
            return [TranscriptSegment(startTime: cueStart, endTime: cueEnd, text: cleaned, speaker: speaker)]
        }
        return segments
    }

    private static let inlineTimestampRegex: NSRegularExpression? = {
        // WebVTT inline tags: <00:01.234> or <00:00:01.234>
        try? NSRegularExpression(pattern: #"<(\d{1,2}):(\d{2})(?::(\d{2}))?\.(\d{3})>"#)
    }()

    private func parseInlineVTTTimestamp(_ match: NSTextCheckingResult, in text: NSString) -> TimeInterval? {
        guard match.numberOfRanges >= 5 else { return nil }
        let minutes = Double(text.substring(with: match.range(at: 1))) ?? 0
        let seconds = Double(text.substring(with: match.range(at: 2))) ?? 0
        let hoursRange = match.range(at: 3)
        let millis = Double(text.substring(with: match.range(at: 4))) ?? 0
        if hoursRange.location != NSNotFound, hoursRange.length > 0 {
            let hours = Double(text.substring(with: hoursRange)) ?? 0
            return hours * 3600 + minutes * 60 + seconds + millis / 1000
        }
        return minutes * 60 + seconds + millis / 1000
    }

    // MARK: - Podcast Index JSON Parser

    func parsePodcastIndexJSON(_ data: Data) -> [TranscriptSegment] {
        struct JSONTranscript: Decodable {
            let segments: [JSONSegment]?
        }
        struct JSONSegment: Decodable {
            let startTime: TimeInterval
            let endTime: TimeInterval?
            let body: String?
            let speaker: String?
        }

        guard let transcript = try? JSONDecoder().decode(JSONTranscript.self, from: data),
              let jsonSegments = transcript.segments else { return [] }

        return jsonSegments.compactMap { seg -> TranscriptSegment? in
            guard let text = seg.body, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return TranscriptSegment(
                startTime: seg.startTime,
                endTime: seg.endTime ?? seg.startTime + 5,
                text: text,
                speaker: seg.speaker
            )
        }
    }

    // MARK: - SRT Parser

    private func parseSRT(_ data: Data) -> [TranscriptSegment] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var segments: [TranscriptSegment] = []
        // SRT blocks are separated by blank lines
        let blocks = text.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard lines.count >= 2 else { continue }

            // Find the timestamp line (contains "-->")
            guard let timeLine = lines.first(where: { $0.contains("-->") }) else { continue }
            let timeParts = timeLine.components(separatedBy: "-->")
            guard timeParts.count == 2,
                  let start = parseSRTTimestamp(timeParts[0].trimmingCharacters(in: .whitespaces)),
                  let end = parseSRTTimestamp(timeParts[1].trimmingCharacters(in: .whitespaces)) else { continue }

            // Text lines are everything after the timestamp line
            let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) ?? 0
            let textLines = lines.dropFirst(timeLineIndex + 1)
            let text = textLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                segments.append(TranscriptSegment(startTime: start, endTime: end, text: text, speaker: nil))
            }
        }

        return segments
    }

    private func parseSRTTimestamp(_ s: String) -> TimeInterval? {
        // SRT format: HH:MM:SS,mmm
        let normalized = s.replacingOccurrences(of: ",", with: ".")
        return parseVTTTimestamp(normalized)
    }
}
