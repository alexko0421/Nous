import Foundation

enum SourceTextExtractor {
    static func readableText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingRegex("(?is)<script\\b[^>]*>.*?</script>", with: " ")
        text = text.replacingRegex("(?is)<style\\b[^>]*>.*?</style>", with: " ")
        text = text.replacingRegex("(?is)<noscript\\b[^>]*>.*?</noscript>", with: " ")
        text = text.replacingRegex("(?is)<br\\s*/?>", with: "\n")
        text = text.replacingRegex("(?is)</p\\s*>", with: "\n")
        text = text.replacingRegex("(?is)</h[1-6]\\s*>", with: "\n")
        text = text.replacingRegex("(?is)<[^>]+>", with: " ")
        text = decodeBasicEntities(text)
        return normalizeWhitespace(text)
    }

    static func title(fromHTML html: String) -> String? {
        guard let range = html.range(
            of: "(?is)<title\\b[^>]*>(.*?)</title>",
            options: .regularExpression
        ) else {
            return nil
        }

        let raw = String(html[range])
            .replacingRegex("(?is)</?title\\b[^>]*>", with: "")
        let title = normalizeWhitespace(decodeBasicEntities(raw))
        return title.isEmpty ? nil : title
    }

    static func normalizeWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .replacingRegex("[\\t ]+", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeBasicEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

private extension String {
    func replacingRegex(_ pattern: String, with replacement: String) -> String {
        replacingOccurrences(
            of: pattern,
            with: replacement,
            options: .regularExpression,
            range: startIndex..<endIndex
        )
    }
}
