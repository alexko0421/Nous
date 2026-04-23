import Foundation

/// One-shot repair pass for conversations whose stored title is still a placeholder,
/// like the old "first user sentence, truncated to 40 chars" seed or a quick-action label.
///
/// The pass is deliberately conservative:
/// - Only conversations that still look like legacy seeds are touched.
/// - If an LLM is available, we use thread memory + a short transcript slice.
/// - If no LLM is available, we fall back to the active conversation memory.
/// - Once no legacy candidates remain, the pass stamps schema_meta so startup
///   stops paying even the candidate-scan cost.
final class ConversationTitleBackfillService {
    static let versionKey = "conversation_title_backfill_version"
    static let targetVersion = "2"

    private struct Candidate {
        var node: NousNode
        let messages: [Message]
        let legacySeed: String?
        let conversationMemory: String?
    }

    private let nodeStore: NodeStore
    private let llmServiceProvider: () -> (any LLMService)?
    private let runLock = NSLock()
    private var isRunning = false

    init(
        nodeStore: NodeStore,
        llmServiceProvider: @escaping () -> (any LLMService)?
    ) {
        self.nodeStore = nodeStore
        self.llmServiceProvider = llmServiceProvider
    }

    func runIfNeeded() async {
        guard beginRun() else { return }
        defer { endRun() }

        do {
            guard try readVersion() == nil else { return }

            let candidates = try fetchCandidates()
            guard !candidates.isEmpty else {
                try writeVersion(Self.targetVersion)
                return
            }

            let llm = llmServiceProvider()
            for candidate in candidates {
                if Task.isCancelled { return }
                guard let title = await resolvedTitle(for: candidate, llm: llm) else { continue }
                try apply(title: title, to: candidate.node)
            }

            if try fetchCandidates().isEmpty {
                try writeVersion(Self.targetVersion)
            }
        } catch {
            #if DEBUG
            print("[ConversationTitleBackfillService] failed: \(error)")
            #endif
        }
    }

    private func beginRun() -> Bool {
        runLock.lock()
        defer { runLock.unlock() }
        if isRunning { return false }
        isRunning = true
        return true
    }

    private func endRun() {
        runLock.lock()
        isRunning = false
        runLock.unlock()
    }

    private func fetchCandidates() throws -> [Candidate] {
        try nodeStore.fetchAllNodes()
            .filter { $0.type == .conversation }
            .compactMap { node in
                let messages = try nodeStore.fetchMessages(nodeId: node.id)
                let legacySeed = Self.legacyConversationSeedTitle(from: messages)
                let trimmedTitle = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isLegacyConversationTitle(trimmedTitle, legacySeed: legacySeed) else {
                    return nil
                }
                let memory = try nodeStore.fetchActiveMemoryEntry(
                    scope: .conversation,
                    scopeRefId: node.id
                )?.content
                let hasUsefulContext = !messages.isEmpty ||
                    !(memory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                guard hasUsefulContext else { return nil }
                return Candidate(
                    node: node,
                    messages: messages,
                    legacySeed: legacySeed,
                    conversationMemory: memory
                )
            }
    }

    private func apply(title: String, to node: NousNode) throws {
        guard node.title != title else { return }
        var updated = node
        updated.title = title
        updated.updatedAt = Date()
        try nodeStore.updateNode(updated)
    }

    private func readVersion() throws -> String? {
        let stmt = try nodeStore.rawDatabase.prepare("SELECT value FROM schema_meta WHERE key = ?;")
        try stmt.bind(Self.versionKey, at: 1)
        guard try stmt.step() else { return nil }
        return stmt.text(at: 0)
    }

    private func writeVersion(_ value: String) throws {
        let stmt = try nodeStore.rawDatabase.prepare("""
            INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?);
        """)
        try stmt.bind(Self.versionKey, at: 1)
        try stmt.bind(value, at: 2)
        try stmt.step()
    }

    private func resolvedTitle(
        for candidate: Candidate,
        llm: (any LLMService)?
    ) async -> String? {
        if let llm,
           let generated = await generateTitle(for: candidate, llm: llm),
           let usable = Self.usableTitle(
               generated,
               currentTitle: candidate.node.title,
               legacySeed: candidate.legacySeed
           ) {
            return usable
        }

        if let fallback = Self.fallbackTitle(
            conversationMemory: candidate.conversationMemory,
            messages: candidate.messages,
            currentTitle: candidate.node.title,
            legacySeed: candidate.legacySeed
        ) {
            return fallback
        }

        return nil
    }

    private func generateTitle(
        for candidate: Candidate,
        llm: any LLMService
    ) async -> String? {
        let memoryBlock = candidate.conversationMemory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recentTranscript = Self.recentTranscriptSnippet(from: candidate.messages, limit: 6)

        var promptParts: [String] = []
        if let memoryBlock, !memoryBlock.isEmpty {
            promptParts.append("Thread memory:\n\(memoryBlock)")
        }
        if !recentTranscript.isEmpty {
            promptParts.append("Recent transcript:\n\(recentTranscript)")
        }
        promptParts.append("Return the best title for this chat. Return title only.")

        do {
            let stream = try await llm.generate(
                messages: [LLMMessage(role: "user", content: promptParts.joined(separator: "\n\n"))],
                system: """
                You write short conversation titles for Nous.
                Rules:
                - Match the conversation language and dialect exactly.
                - Do not translate Cantonese into Mandarin.
                - Output title text only. No tags, bullets, markdown, quotes, or explanation.
                - No trailing punctuation. No emoji.
                - Keep it specific and compact.
                """
            )

            var output = ""
            for try await chunk in stream {
                if Task.isCancelled { return nil }
                output += chunk
            }
            return output
        } catch {
            return nil
        }
    }

    private static func fallbackTitle(
        conversationMemory: String?,
        messages: [Message],
        currentTitle: String,
        legacySeed: String?
    ) -> String? {
        if let conversationMemory {
            for line in extractSummaryLines(from: conversationMemory, limit: 3) {
                let reduced = reducedTopicPhrase(from: line)
                if let usable = usableTitle(reduced, currentTitle: currentTitle, legacySeed: legacySeed) {
                    return usable
                }
            }
        }

        guard let firstUser = messages.first(where: { $0.role == .user })?.content else { return nil }
        let queryOnly = firstUser
            .components(separatedBy: "\n\nFiles:")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? firstUser
        let reduced = reducedTopicPhrase(from: queryOnly)
        return usableTitle(reduced, currentTitle: currentTitle, legacySeed: legacySeed)
    }

    private static func recentTranscriptSnippet(from messages: [Message], limit: Int) -> String {
        messages
            .suffix(limit)
            .map { message in
                let speaker = message.role == .user ? "Alex" : "Nous"
                return "\(speaker): \(message.content)"
            }
            .joined(separator: "\n\n")
    }

    private static func usableTitle(
        _ raw: String?,
        currentTitle: String,
        legacySeed: String?
    ) -> String? {
        guard var title = sanitizeTitle(raw) else { return nil }

        let lower = title.lowercased()
        let banned = [
            "new conversation",
            "new chat",
            "untitled",
            "title",
            "chat title"
        ]
        guard !banned.contains(lower) else { return nil }
        guard title != currentTitle else { return nil }
        if let legacySeed {
            guard title != legacySeed else { return nil }
        }

        if title.hasPrefix("Alex ") && title.count > 5 {
            title = String(title.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return title.isEmpty ? nil : title
    }

    static func sanitizeTitle(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }

        if let firstLine = title.components(separatedBy: .newlines).first {
            title = firstLine
        }

        if title.hasPrefix("<chat_title>"),
           let extracted = ClarificationCardParser.extractChatTitle(from: title) {
            title = extracted
        }

        let prefixedLeadIns = ["Title:", "title:", "Chat title:", "chat title:", "标题：", "標題：", "标题:", "標題:"]
        for leadIn in prefixedLeadIns where title.hasPrefix(leadIn) {
            title = String(title.dropFirst(leadIn.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        title = title
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
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

    private static func isLegacyConversationTitle(_ title: String, legacySeed: String?) -> Bool {
        if let legacySeed, title == legacySeed { return true }
        if QuickActionMode.isPlaceholderConversationTitle(title) { return true }
        return ["new conversation", "new chat", "untitled"].contains(title.lowercased())
    }

    private static func legacyConversationSeedTitle(from messages: [Message]) -> String? {
        guard let firstUser = messages.first(where: { $0.role == .user })?.content else {
            return nil
        }
        let queryOnly = firstUser
            .components(separatedBy: "\n\nFiles:")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? firstUser
        guard !queryOnly.isEmpty else { return nil }
        return String(queryOnly.prefix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractSummaryLines(from content: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }

        var lines: [String] = []
        var seen: Set<String> = []

        for rawLine in content.components(separatedBy: .newlines) {
            var trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !trimmed.hasPrefix("#") else { continue }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("•") {
                trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard !trimmed.isEmpty else { continue }
            let key = normalizedLine(trimmed)
            guard seen.insert(key).inserted else { continue }
            lines.append(trimmed)
            if lines.count == limit { break }
        }

        return lines
    }

    private static func reducedTopicPhrase(from text: String) -> String {
        let prefixes = [
            "Alex wants to figure out ",
            "Alex wants clarity on ",
            "Alex is trying to figure out ",
            "Alex is trying to decide whether to ",
            "Alex is trying to decide ",
            "Alex is deciding whether to ",
            "Alex is deciding ",
            "Alex is asking about ",
            "Alex needs help with ",
            "Alex wants help with ",
            "Alex wants to ",
            "Alex wants ",
            "Alex is worried about ",
            "Alex is thinking about ",
            "Alex is exploring ",
            "Alex 想搞清楚",
            "Alex 想知道",
            "Alex 想问",
            "Alex 想",
            "Alex 正考虑",
            "Alex 考虑",
            "Alex 在想",
            "Alex 问",
            "Alex 纠结",
            "Alex 糾結",
        ]

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in prefixes {
            if trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    private static func normalizedLine(_ content: String) -> String {
        content
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
