import Foundation

struct NormalizedAssistantTurn: Equatable {
    let rawAssistantContent: String
    let assistantContent: String
    let conversationTitle: String?
}

enum AssistantTurnNormalizer {
    static func normalize(_ rawAssistantContent: String) -> NormalizedAssistantTurn {
        NormalizedAssistantTurn(
            rawAssistantContent: rawAssistantContent,
            assistantContent: ClarificationCardParser.stripChatTitle(from: rawAssistantContent),
            conversationTitle: sanitizedConversationTitle(
                from: ClarificationCardParser.extractChatTitle(from: rawAssistantContent)
            )
        )
    }

    static func sanitizedConversationTitle(from raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }

        title = title
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while title.contains("  ") {
            title = title.replacingOccurrences(of: "  ", with: " ")
        }

        while let first = title.first, first == "#" || first == "-" || first == "*" || first.isWhitespace {
            title.removeFirst()
        }

        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:。！？、，；："))

        let filteredScalars = title.unicodeScalars.filter { scalar in
            !CharacterSet(charactersIn: "<>|/\\").contains(scalar)
        }
        title = String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if title.count > 48 {
            title = String(title.prefix(48)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return title.isEmpty ? nil : title
    }
}
