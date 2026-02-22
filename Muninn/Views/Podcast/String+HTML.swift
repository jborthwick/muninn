import Foundation

extension String {
    /// Strips HTML tags and decodes entities (e.g. `&amp;` → `&`).
    /// Uses NSAttributedString HTML parsing; falls back to a simple regex strip.
    var htmlStripped: String {
        guard let data = data(using: .utf8),
              let nsAttr = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue
                  ],
                  documentAttributes: nil
              )
        else {
            return replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nsAttr.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
