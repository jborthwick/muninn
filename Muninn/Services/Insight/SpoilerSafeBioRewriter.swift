import Foundation
import FoundationModels

/// Rewrites wiki character intros into short spoiler-safe blurbs on-device.
enum SpoilerSafeBioRewriter {
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    static func rewrite(
        name: String,
        role: String?,
        intro: String,
        episodeTitle: String,
        inEpisodeHint: String?
    ) async -> String? {
        guard isAvailable else { return nil }

        // Strip inch-mark quotes so guided generation doesn't truncate mid-string
        // on heights like 6'6".
        let safeIntro = sanitizeForModel(intro)
        let safeHint = inEpisodeHint.map(sanitizeForModel)
        let roleLine = role.map { "Role: \($0)." } ?? ""
        let hintLine = safeHint.map { "In this episode (may mention them): \($0)" } ?? ""

        let session = LanguageModelSession(instructions: """
        You write spoiler-safe character cards for a podcast companion app.
        Use ONLY facts present in the provided wiki intro text.
        Do not invent plot, deaths, romance, identity reveals, or future events.
        Prefer identity, role, and vibe in 1–2 short sentences.
        If the intro is thin, say only what is clearly known.
        Spell out heights (e.g. 6-foot-6) — never use inch-mark quotes.
        Episode context: "\(sanitizeForModel(episodeTitle))"
        """)

        let prompt = """
        Character: \(name)
        \(roleLine)
        Wiki intro (source material — do not add beyond this):
        \(safeIntro)
        \(hintLine)

        Write a spoiler-safe character card.
        """

        do {
            let response = try await session.respond(
                to: prompt,
                generating: SpoilerSafeBioPlan.self
            )
            let text = response.content.blurb.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPlausibleBlurb(text) else {
                return fallbackBlurb(name: name, role: role, intro: intro)
            }
            return text
        } catch {
            return fallbackBlurb(name: name, role: role, intro: intro)
        }
    }

    /// Truncated first sentences when Foundation Models are unavailable.
    static func fallbackBlurb(name: String, role: String?, intro: String) -> String {
        let trimmed = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = firstSentences(trimmed, max: 2)
        if let role, !role.isEmpty {
            return "\(name) (\(role)). \(sentence)"
        }
        return sentence.isEmpty ? "\(name)." : sentence
    }

    /// Avoid `"` marks that break guided-generation string fields.
    nonisolated static func sanitizeForModel(_ text: String) -> String {
        var result = text
        // 6'6" / 6′6″ → 6-foot-6
        result = result.replacingOccurrences(
            of: #"(\d+)\s*['′]\s*(\d+)\s*[\"″]"#,
            with: "$1-foot-$2",
            options: .regularExpression
        )
        result = result
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\u{201C}", with: "")
            .replacingOccurrences(of: "\u{201D}", with: "")
            .replacingOccurrences(of: "\u{2033}", with: "")
        return result
    }

    nonisolated static func isPlausibleBlurb(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 48 else { return false }
        // Truncation often ends right after a height fragment.
        if trimmed.range(of: #"\d+['′]\d*\s*[\"″]?\s*$"#, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    private static func firstSentences(_ text: String, max: Int) -> String {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { sentences.append(s) }
                current = ""
                if sentences.count >= max { break }
            }
        }
        if sentences.count < max {
            let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { sentences.append(rest) }
        }
        let joined = sentences.prefix(max).joined(separator: " ")
        if joined.count > 280 {
            return String(joined.prefix(277)) + "…"
        }
        return joined
    }
}

@Generable
private struct SpoilerSafeBioPlan {
    @Guide(description: "1–2 short spoiler-safe sentences about the character. No quotation marks.")
    var blurb: String
}
