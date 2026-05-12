import Foundation

struct SourceBriefingRequest: Equatable {
    let currentFocus: String?
    let projectContext: String?
    let rememberedTheses: [String]
    let sourceMaterials: [SourceMaterialContext]
    let maxItems: Int

    init(
        currentFocus: String?,
        projectContext: String?,
        rememberedTheses: [String],
        sourceMaterials: [SourceMaterialContext],
        maxItems: Int = 5
    ) {
        self.currentFocus = currentFocus
        self.projectContext = projectContext
        self.rememberedTheses = rememberedTheses
        self.sourceMaterials = sourceMaterials
        self.maxItems = max(1, maxItems)
    }
}

struct SourceBriefing: Codable, Equatable {
    let title: String?
    let items: [SourceBriefingItem]

    static let empty = SourceBriefing(title: nil, items: [])
}

struct SourceBriefingItem: Codable, Equatable {
    let sourceNodeId: UUID
    let headline: String
    let whatChanged: String
    let whyItMatters: String
    let alexRelevance: String
    let tensionOrRisk: String
    let suggestedNextAction: String
    let evidence: String
    let confidence: Double
}

enum SourcePromptLimits {
    static let chunksPerSource = 3
}

enum SourceBriefingText {
    static let titleLimit = 120
    static let headlineLimit = 140
    static let bodyLimit = 360
    static let evidenceLimit = 240

    static func title(_ text: String?) -> String? {
        sanitized(text, limit: titleLimit)
    }

    static func headline(_ text: String?) -> String? {
        sanitized(text, limit: headlineLimit)
    }

    static func body(_ text: String?) -> String? {
        sanitized(text, limit: bodyLimit)
    }

    static func evidence(_ text: String?) -> String? {
        sanitized(text, limit: evidenceLimit)
    }

    static func sanitized(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let cleanedLines = text
            .components(separatedBy: .newlines)
            .map(cleanedLine)
            .filter { !$0.isEmpty && !isInstructionLikeLine($0) }
        let normalized = cleanedLines
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedLine(_ text: String) -> String {
        var line = text
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let bulletPrefixes = ["- ", "* ", "• "]
        for prefix in bulletPrefixes where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return line
    }

    private static func isInstructionLikeLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        let blockedFragments = [
            "ignore previous",
            "disregard previous",
            "forget previous",
            "do not follow this",
            "system prompt",
            "developer message",
            "assistant instruction",
            "you are chatgpt",
            "you must now",
            "call the tool",
            "execute command",
            "run shell",
            "tool_call"
        ]
        if blockedFragments.contains(where: lowercased.contains) {
            return true
        }

        return line.range(
            of: #"</?(system|assistant|user|tool|script|xml)[^>]*>"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
