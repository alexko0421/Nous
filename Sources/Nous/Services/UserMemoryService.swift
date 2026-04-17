import Foundation

/// Three-scope memory service (v2.1). Replaces the single global-blob refresh
/// with per-conversation / per-project / global layers. See
/// `.context/plans/cross-chat-memory-v2.md` §5 for the architecture.
final class UserMemoryService {

    // Per-layer token budgets from plan §6. Cap at read time so the database
    // can hold longer content if needed but the prompt stays bounded.
    static let globalBudget = 600
    static let projectBudget = 400
    static let conversationBudget = 200

    private let nodeStore: NodeStore
    private let llmServiceProvider: () -> (any LLMService)?

    init(
        nodeStore: NodeStore,
        llmServiceProvider: @escaping () -> (any LLMService)?
    ) {
        self.nodeStore = nodeStore
        self.llmServiceProvider = llmServiceProvider
    }

    // MARK: - Read (used by ChatViewModel.assembleContext)

    func currentGlobal() -> String? {
        let content = (try? nodeStore.fetchGlobalMemory())?.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self.cap(content, budget: Self.globalBudget)
    }

    func currentProject(projectId: UUID) -> String? {
        let content = (try? nodeStore.fetchProjectMemory(projectId: projectId))?.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self.cap(content, budget: Self.projectBudget)
    }

    func currentConversation(nodeId: UUID) -> String? {
        let content = (try? nodeStore.fetchConversationMemory(nodeId: nodeId))?.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self.cap(content, budget: Self.conversationBudget)
    }

    // MARK: - Write

    /// Called after each completed send. Summarises **only** Alex's user-role
    /// turns for this chat. Assistant turns are excluded to prevent the
    /// self-confirmation loop (Nous's own replies becoming next turn's evidence).
    func refreshConversation(nodeId: UUID, messages: [Message]) async {
        let userTurns = messages
            .filter { $0.role == .user }
            .suffix(8)
            .map(\.content)
            .joined(separator: "\n---\n")

        guard !userTurns.isEmpty else { return }
        guard let llm = llmServiceProvider() else { return }

        let existing = currentConversation(nodeId: nodeId) ?? ""
        let existingBlock = existing.isEmpty ? "[none yet]" : existing

        let prompt = """
        Existing thread memory for this chat:
        \(existingBlock)

        Recent things Alex said (ALEX ONLY — Nous's replies are intentionally omitted to avoid self-confirmation loops):
        \(userTurns)

        Rewrite a SHORT memory note for THIS chat's thread only.
        - What is Alex trying to do in this chat?
        - What has he told me that I should remember while this chat continues?
        - Do NOT include general facts about Alex — those belong in other memory layers.
        - Keep under 6 bullet points. Markdown only.
        """

        do {
            let stream = try await llm.generate(
                messages: [LLMMessage(role: "user", content: prompt)],
                system: """
                You maintain the short thread memory for one chat in Nous.
                Only write things Alex himself said or clearly implied.
                Never invent facts. Keep it tight.
                Return Markdown only.
                """
            )

            var updated = ""
            for try await chunk in stream {
                updated += chunk
            }

            let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            try? nodeStore.saveConversationMemory(
                ConversationMemory(nodeId: nodeId, content: trimmed, updatedAt: Date())
            )
        } catch {
            return
        }
    }

    /// Aggregates all conversation_memory rows for nodes in this project into a
    /// single project-level blob. Called by `UserMemoryScheduler` on a counter
    /// cadence (every N conversation refreshes in the same project).
    func refreshProject(projectId: UUID) async {
        guard let nodes = try? nodeStore.fetchNodes(projectId: projectId) else { return }

        let convoBlobs = nodes.compactMap { node -> String? in
            guard let memory = try? nodeStore.fetchConversationMemory(nodeId: node.id) else {
                return nil
            }
            let trimmed = memory.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return "[\(node.title)]\n\(trimmed)"
        }

        guard !convoBlobs.isEmpty else { return }
        guard let llm = llmServiceProvider() else { return }

        let joined = convoBlobs.joined(separator: "\n\n---\n\n")
        let existing = currentProject(projectId: projectId) ?? ""
        let existingBlock = existing.isEmpty ? "[none yet]" : existing

        let prompt = """
        Existing project-level memory:
        \(existingBlock)

        Short summaries of this project's recent chats:
        \(joined)

        Write a short project-level memory: what recurs across these chats, what persists beyond any single chat?
        - Focus on durable project context, decisions, constraints, recurring themes.
        - Do NOT restate identity-level facts about Alex — those live in the global layer.
        - Keep under 8 bullet points. Markdown only.
        """

        do {
            let stream = try await llm.generate(
                messages: [LLMMessage(role: "user", content: prompt)],
                system: """
                You maintain per-project memory for Nous.
                Only include things that recur or persist across multiple chats in the project.
                Never invent facts. Markdown only.
                """
            )

            var updated = ""
            for try await chunk in stream {
                updated += chunk
            }

            let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            try? nodeStore.saveProjectMemory(
                ProjectMemory(projectId: projectId, content: trimmed, updatedAt: Date())
            )
        } catch {
            return
        }
    }

    /// v1: invoked by the Memory Inspector UI when Alex explicitly promotes a
    /// project-level fact to identity level. v2 will auto-promote when the same
    /// fact recurs across ≥3 projects.
    func promoteToGlobal(candidate: String) async {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty else { return }
        guard let llm = llmServiceProvider() else { return }

        let existing = currentGlobal() ?? ""
        let existingBlock = existing.isEmpty ? "[none yet]" : existing

        let prompt = """
        Existing identity-level memory about Alex:
        \(existingBlock)

        New candidate fact to fold in:
        \(trimmedCandidate)

        Merge the candidate into the existing identity memory. Deduplicate; prefer the most precise wording.
        - Keep only durable identity-level facts (who Alex is, core values, deep patterns).
        - Do NOT include project-specific or conversation-specific details.
        - Return the full updated Markdown memory, under 6 bullet points.
        """

        do {
            let stream = try await llm.generate(
                messages: [LLMMessage(role: "user", content: prompt)],
                system: """
                You maintain Alex's identity-level memory for Nous.
                Only keep durable facts. Never invent.
                Return the full updated Markdown blob.
                """
            )

            var updated = ""
            for try await chunk in stream {
                updated += chunk
            }

            let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            try? nodeStore.saveGlobalMemory(
                GlobalMemory(content: trimmed, updatedAt: Date())
            )
        } catch {
            return
        }
    }

    // MARK: - Helpers

    /// Returns trimmed content capped at `budget` characters, or nil if empty.
    /// Truncates at the last newline before the cap to avoid mid-line cuts.
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
}
