import Foundation

struct MemoryGraphEvidenceMatch {
    let message: Message
    let quote: String
}

enum MemoryGraphEvidenceMatcher {
    static func match(
        evidenceMessageId: UUID?,
        evidenceQuote: String?,
        messages: [Message]
    ) -> MemoryGraphEvidenceMatch? {
        let quote = evidenceQuote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !quote.isEmpty else { return nil }

        if let evidenceMessageId,
           let exactMessage = messages.first(where: { $0.id == evidenceMessageId }),
           quoteMatches(quote, content: exactMessage.content) {
            return MemoryGraphEvidenceMatch(message: exactMessage, quote: quote)
        }

        for message in messages where quoteMatches(quote, content: message.content) {
            return MemoryGraphEvidenceMatch(message: message, quote: quote)
        }

        return nil
    }

    static func quoteMatches(_ quote: String, content: String) -> Bool {
        let normalizedQuote = normalizedEvidence(quote)
        let normalizedContent = normalizedEvidence(content)
        guard !normalizedQuote.isEmpty, !normalizedContent.isEmpty else { return false }
        if normalizedContent.contains(normalizedQuote) { return true }
        return tokenJaccard(normalizedQuote, normalizedContent) >= 0.45
    }

    private static func normalizedEvidence(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func tokenJaccard(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(tokens(lhs))
        let right = Set(tokens(rhs))
        guard left.count >= 3, right.count >= 3 else { return 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private static func tokens(_ text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }
}
