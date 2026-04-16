import Foundation

enum ParsedResponse {
    case plain(String)
    case card(CardPayload)
    case defer_
}

enum ResponseTagParser {
    static func parse(_ raw: String) -> ParsedResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Defer: response is exactly <defer/> (with any whitespace around).
        if trimmed == "<defer/>" {
            return .defer_
        }

        // Try to parse <card>...</card>.
        if let cardRange = trimmed.range(of: "<card>"),
           let cardEnd = trimmed.range(of: "</card>", range: cardRange.upperBound..<trimmed.endIndex) {
            let inner = String(trimmed[cardRange.upperBound..<cardEnd.lowerBound])
            if let payload = parseCardInner(inner) {
                return .card(payload)
            }
            // Malformed card → fall through to plain.
        }

        // Strip stray <defer/> from mixed content.
        let cleaned = trimmed.replacingOccurrences(of: "<defer/>", with: "")
        return .plain(cleaned)
    }

    private static func parseCardInner(_ inner: String) -> CardPayload? {
        let framing = firstMatch(pattern: "<framing>(.*?)</framing>", in: inner) ?? ""
        let options = allMatches(pattern: "<option>(.*?)</option>", in: inner)
        guard !options.isEmpty else { return nil }
        return CardPayload(framing: framing.trimmingCharacters(in: .whitespacesAndNewlines),
                           options: options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, range: range),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func allMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { m in
            guard m.numberOfRanges >= 2,
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }
}
