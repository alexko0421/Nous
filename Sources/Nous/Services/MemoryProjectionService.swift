import Foundation

final class MemoryProjectionService {
    // Per-layer prompt budgets. The projection service owns read-time caps so
    // canonical memory entries can stay richer than the context slice.
    static let globalBudget = 600
    static let essentialStoryBudget = 500
    static let projectBudget = 400
    static let conversationBudget = 200
    static let evidenceSnippetBudget = 180
    static let userModelFacetLimit = 3

    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func currentGlobal() -> String? {
        let content = readActiveEntry(scope: .global, scopeRefId: nil)
        return Self.cap(content, budget: Self.globalBudget)
    }

    func currentProject(projectId: UUID) -> String? {
        let content = readActiveEntry(scope: .project, scopeRefId: projectId)
        return Self.cap(content, budget: Self.projectBudget)
    }

    func currentConversation(nodeId: UUID) -> String? {
        let content = readActiveEntry(scope: .conversation, scopeRefId: nodeId)
        return Self.cap(content, budget: Self.conversationBudget)
    }

    func currentEssentialStory(
        projectId: UUID?,
        excludingConversationId: UUID? = nil
    ) -> String? {
        let globalMemory = readActiveEntry(scope: .global, scopeRefId: nil)

        var projectTitle: String?
        var projectMemory = ""
        if let projectId {
            projectTitle = (try? nodeStore.fetchProject(id: projectId))?.title ?? "Untitled Project"
            projectMemory = readActiveEntry(scope: .project, scopeRefId: projectId)
        }

        let recentConversations = (try? nodeStore.fetchRecentConversationMemories(
            limit: 2,
            excludingId: excludingConversationId
        )) ?? []

        var lines: [String] = []
        var seen: Set<String> = []

        for line in Self.extractSummaryLines(from: projectMemory, limit: 2) {
            let formatted = "- Current project (\(projectTitle ?? "Untitled Project")): \(line)"
            let key = Self.normalizedLine(formatted)
            if seen.insert(key).inserted {
                lines.append(formatted)
            }
        }

        for conversation in recentConversations {
            let summary = Self.extractSummaryLines(from: conversation.memory, limit: 1).first
                ?? Self.preview(conversation.memory, maxChars: 140)
            guard !summary.isEmpty else { continue }
            let formatted = "- Recent thread (\(conversation.title)): \(summary)"
            let key = Self.normalizedLine(formatted)
            if seen.insert(key).inserted {
                lines.append(formatted)
            }
        }

        if !lines.isEmpty,
           let backdrop = Self.extractSummaryLines(from: globalMemory, limit: 1).first {
            let formatted = "- Stable backdrop: \(backdrop)"
            let key = Self.normalizedLine(formatted)
            if seen.insert(key).inserted {
                lines.insert(formatted, at: 0)
            }
        }

        guard !lines.isEmpty else { return nil }
        return Self.cap(lines.joined(separator: "\n"), budget: Self.essentialStoryBudget)
    }

    func currentBoundedEvidence(
        projectId: UUID?,
        excludingConversationId: UUID? = nil,
        limit: Int = 2
    ) -> [MemoryEvidenceSnippet] {
        guard limit > 0 else { return [] }

        var candidates: [(label: String, entry: MemoryEntry)] = []

        if let projectId,
           let projectEntry = try? nodeStore.fetchActiveMemoryEntry(scope: .project, scopeRefId: projectId),
           !projectEntry.sourceNodeIds.isEmpty {
            candidates.append(("Project context", projectEntry))
        }

        let recentConversationEntries = ((try? nodeStore.fetchMemoryEntries()) ?? [])
            .filter { $0.scope == .conversation && $0.status == .active }
            .filter { entry in
                guard let scopeRefId = entry.scopeRefId else { return false }
                return scopeRefId != excludingConversationId
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(2)

        for entry in recentConversationEntries where !entry.sourceNodeIds.isEmpty {
            candidates.append(("Recent thread", entry))
        }

        if let globalEntry = try? nodeStore.fetchActiveMemoryEntry(scope: .global, scopeRefId: nil),
           !globalEntry.sourceNodeIds.isEmpty {
            candidates.append(("Long-term memory", globalEntry))
        }

        var snippets: [MemoryEvidenceSnippet] = []
        var usedSourceNodeIds: Set<UUID> = []

        for candidate in candidates {
            guard let snippet = selectEvidenceSnippet(
                for: candidate.entry,
                label: candidate.label,
                excludingConversationId: excludingConversationId,
                usedSourceNodeIds: &usedSourceNodeIds
            ) else {
                continue
            }
            snippets.append(snippet)
            if snippets.count == limit { break }
        }

        return snippets
    }

    func currentIdentityModel() -> [String] {
        guard let globalEntry = try? nodeStore.fetchActiveMemoryEntry(scope: .global, scopeRefId: nil),
              globalEntry.confidence >= 0.8 else {
            return []
        }
        return Array(
            Self.extractSummaryLines(from: globalEntry.content, limit: Self.userModelFacetLimit)
                .prefix(Self.userModelFacetLimit)
        )
    }

    func currentGoalModel(projectId: UUID?, conversationId: UUID? = nil) -> [String] {
        var lines: [String] = []
        var seen: Set<String> = []

        if let projectId,
           let project = try? nodeStore.fetchProject(id: projectId),
           !project.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmedGoal = project.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.normalizedLine(trimmedGoal)
            if seen.insert(key).inserted {
                lines.append(trimmedGoal)
            }
        }

        for line in facetLines(
            from: goalModelEntries(projectId: projectId, conversationId: conversationId),
            keywords: [
                "goal", "build", "ship", "trying to", "want to", "wants to",
                "priority", "focus", "plan to", "need to"
            ],
            minConfidence: 0.8,
            limit: Self.userModelFacetLimit
        ) {
            let key = Self.normalizedLine(line)
            guard seen.insert(key).inserted else { continue }
            lines.append(line)
            if lines.count == Self.userModelFacetLimit { break }
        }

        return lines
    }

    func currentWorkStyleModel(projectId: UUID?, conversationId: UUID? = nil) -> [String] {
        facetLines(
            from: workStyleEntries(projectId: projectId, conversationId: conversationId),
            keywords: [
                "prefer", "prefers", "direct", "simple", "first principles",
                "challenge", "support", "framing", "concise", "control",
                "fast", "deliberate"
            ],
            minConfidence: 0.85,
            limit: Self.userModelFacetLimit
        )
    }

    func currentMemoryBoundary(projectId: UUID?, conversationId: UUID? = nil) -> [String] {
        facetLines(
            from: boundaryEntries(projectId: projectId, conversationId: conversationId),
            keywords: [
                "remember", "memory", "store", "stored", "privacy",
                "permission", "ask first", "boundary", "do not store",
                "don't store", "do not keep", "consent", "ask before"
            ],
            minConfidence: 0.8,
            limit: 2
        )
    }

    func currentUserModel(projectId: UUID?, conversationId: UUID? = nil) -> UserModel? {
        let model = UserModel(
            identity: currentIdentityModel(),
            goals: currentGoalModel(projectId: projectId, conversationId: conversationId),
            workStyle: currentWorkStyleModel(projectId: projectId, conversationId: conversationId),
            memoryBoundary: currentMemoryBoundary(projectId: projectId, conversationId: conversationId)
        )
        return model.isEmpty ? nil : model
    }

    func currentDecisionGraphRecall(
        currentMessage: String,
        projectId: UUID?,
        conversationId: UUID,
        limit: Int = 3,
        now: Date = Date()
    ) -> [String] {
        MemoryQueryPlanner(nodeStore: nodeStore).recall(
            currentMessage: currentMessage,
            projectId: projectId,
            conversationId: conversationId,
            limit: limit,
            allowedIntents: [.decisionHistory],
            now: now
        )
    }

    func currentGraphMemoryRecall(
        currentMessage: String,
        projectId: UUID?,
        conversationId: UUID,
        limit: Int = 4,
        queryEmbedding: [Float]? = nil,
        now: Date = Date()
    ) -> [String] {
        MemoryQueryPlanner(nodeStore: nodeStore).recall(
            currentMessage: currentMessage,
            projectId: projectId,
            conversationId: conversationId,
            limit: limit,
            queryEmbedding: queryEmbedding,
            now: now
        )
    }

    func memoryPersistenceDecision(messages: [Message], projectId: UUID?) -> MemoryPersistenceDecision {
        guard let latestUserMessage = messages.reversed().first(where: { $0.role == .user }) else {
            return .persist
        }

        let latestContent = Self.stripQuoteBlocks(latestUserMessage.content)
        let boundaries = currentMemoryBoundary(projectId: projectId)
        return MemoryCurator()
            .assess(latestUserText: latestContent, boundaryLines: boundaries)
            .persistenceDecision
    }

    func shouldPersistMemory(messages: [Message], projectId: UUID?) -> Bool {
        memoryPersistenceDecision(
            messages: messages,
            projectId: projectId
        ).shouldPersist
    }

    private func readActiveEntry(scope: MemoryScope, scopeRefId: UUID?) -> String {
        guard let entry = try? nodeStore.fetchActiveMemoryEntry(scope: scope, scopeRefId: scopeRefId) else {
            return ""
        }
        return entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectEvidenceSnippet(
        for entry: MemoryEntry,
        label: String,
        excludingConversationId: UUID?,
        usedSourceNodeIds: inout Set<UUID>
    ) -> MemoryEvidenceSnippet? {
        for sourceNodeId in dedupeSourceNodeIds(entry.sourceNodeIds) {
            if let excludingConversationId, sourceNodeId == excludingConversationId {
                continue
            }
            guard !usedSourceNodeIds.contains(sourceNodeId) else { continue }
            guard let node = try? nodeStore.fetchNode(id: sourceNodeId) else { continue }
            let snippet = extractEvidenceSnippet(from: node)
            guard !snippet.isEmpty else { continue }
            usedSourceNodeIds.insert(sourceNodeId)
            return MemoryEvidenceSnippet(
                label: label,
                sourceNodeId: sourceNodeId,
                sourceTitle: node.title,
                snippet: snippet
            )
        }
        return nil
    }

    private func extractEvidenceSnippet(from node: NousNode) -> String {
        switch node.type {
        case .conversation:
            if let recentUserMessage = recentUserEvidence(nodeId: node.id) {
                return recentUserMessage
            }
            if let transcriptExcerpt = alexTranscriptEvidence(node.content) {
                return transcriptExcerpt
            }
        case .note:
            break
        }

        for line in Self.extractSummaryLines(from: node.content, limit: 1) where !line.isEmpty {
            return Self.preview(line, maxChars: Self.evidenceSnippetBudget)
        }

        return Self.preview(node.content, maxChars: Self.evidenceSnippetBudget)
    }

    private func goalModelEntries(projectId: UUID?, conversationId: UUID?) -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        if let projectId,
           let projectEntry = try? nodeStore.fetchActiveMemoryEntry(scope: .project, scopeRefId: projectId) {
            entries.append(projectEntry)
        }
        if let conversationId,
           let conversationEntry = try? nodeStore.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: conversationId) {
            entries.append(conversationEntry)
        }
        entries.append(contentsOf: recentActiveConversationEntries(excludingConversationId: conversationId, limit: 2))
        return entries
    }

    private func workStyleEntries(projectId: UUID?, conversationId: UUID?) -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        if let globalEntry = try? nodeStore.fetchActiveMemoryEntry(scope: .global, scopeRefId: nil) {
            entries.append(globalEntry)
        }
        if let projectId,
           let projectEntry = try? nodeStore.fetchActiveMemoryEntry(scope: .project, scopeRefId: projectId) {
            entries.append(projectEntry)
        }
        if let conversationId,
           let conversationEntry = try? nodeStore.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: conversationId) {
            entries.append(conversationEntry)
        }
        return entries
    }

    private func boundaryEntries(projectId: UUID?, conversationId: UUID?) -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        if let globalEntry = try? nodeStore.fetchActiveMemoryEntry(scope: .global, scopeRefId: nil) {
            entries.append(globalEntry)
        }
        if let projectId,
           let projectEntry = try? nodeStore.fetchActiveMemoryEntry(scope: .project, scopeRefId: projectId) {
            entries.append(projectEntry)
        }
        if let conversationId,
           let conversationEntry = try? nodeStore.fetchActiveMemoryEntry(scope: .conversation, scopeRefId: conversationId) {
            entries.append(conversationEntry)
        }
        entries.append(contentsOf: recentActiveConversationEntries(excludingConversationId: conversationId, limit: 2))
        return entries
    }

    private func recentActiveConversationEntries(
        excludingConversationId: UUID?,
        limit: Int
    ) -> [MemoryEntry] {
        guard limit > 0 else { return [] }
        return ((try? nodeStore.fetchMemoryEntries()) ?? [])
            .filter { $0.scope == .conversation && $0.status == .active }
            .filter { entry in
                guard let scopeRefId = entry.scopeRefId else { return false }
                return scopeRefId != excludingConversationId
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { $0 }
    }

    private func facetLines(
        from entries: [MemoryEntry],
        keywords: [String],
        minConfidence: Double,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }

        let normalizedKeywords = keywords.map(Self.normalizedLine)
        var lines: [String] = []
        var seen: Set<String> = []

        for entry in entries where entry.status == .active && entry.confidence >= minConfidence {
            for line in Self.extractSummaryLines(from: entry.content, limit: 12) {
                let normalized = Self.normalizedLine(line)
                guard !normalized.isEmpty else { continue }
                guard normalizedKeywords.contains(where: { normalized.contains($0) }) else { continue }
                guard seen.insert(normalized).inserted else { continue }
                lines.append(line)
                if lines.count == limit { return lines }
            }
        }

        return lines
    }

    private func recentUserEvidence(nodeId: UUID) -> String? {
        guard let messages = try? nodeStore.fetchMessages(nodeId: nodeId) else { return nil }

        for message in messages.reversed() where message.role == .user {
            let cleaned = Self.stripQuoteBlocks(message.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            return Self.preview(cleaned, maxChars: Self.evidenceSnippetBudget)
        }

        return nil
    }

    private func alexTranscriptEvidence(_ transcript: String) -> String? {
        let turns = transcript.components(separatedBy: "\n\n")
        for turn in turns.reversed() {
            let trimmed = turn.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("Alex:") else { continue }
            let content = trimmed.dropFirst("Alex:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            return Self.preview(content, maxChars: Self.evidenceSnippetBudget)
        }
        return nil
    }

    private func dedupeSourceNodeIds(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    static func stripQuoteBlocks(_ content: String) -> String {
        content
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")
    }

    private static func cap(_ content: String, budget: Int) -> String? {
        guard !content.isEmpty else { return nil }
        guard content.count > budget else { return content }

        let limit = content.index(content.startIndex, offsetBy: budget)
        let head = content[..<limit]
        if let lastNewline = head.lastIndex(of: "\n") {
            return String(content[..<lastNewline]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(head)
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

    private static func preview(_ content: String, maxChars: Int) -> String {
        let trimmed = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed }
        let limit = trimmed.index(trimmed.startIndex, offsetBy: maxChars)
        return String(trimmed[..<limit]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedLine(_ content: String) -> String {
        content
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
