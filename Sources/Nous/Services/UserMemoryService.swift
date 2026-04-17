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

    /// v2.2c cutover: reads come from the active `memory_entries` row, not the
    /// legacy v2.1 blob. The blob is still written (v2.2b dual-write) as a
    /// safety net — if some edge case leaves an entry missing (migrator bug,
    /// partial write), we fall back to the blob so the user never sees a
    /// silent memory wipe. Fallback removal is deferred to v2.2d after soak.
    ///
    /// Content parity (entry.content == blob.content for the same scope+ref)
    /// is enforced at write time (see `writeScopeEntry`) so this cutover is a
    /// non-semantic flip by construction.
    func currentGlobal() -> String? {
        let content = readActiveEntryOrBlob(
            scope: .global,
            scopeRefId: nil,
            blobContent: { (try? nodeStore.fetchGlobalMemory())?.content }
        )
        return Self.cap(content, budget: Self.globalBudget)
    }

    func currentProject(projectId: UUID) -> String? {
        let content = readActiveEntryOrBlob(
            scope: .project,
            scopeRefId: projectId,
            blobContent: { (try? nodeStore.fetchProjectMemory(projectId: projectId))?.content }
        )
        return Self.cap(content, budget: Self.projectBudget)
    }

    func currentConversation(nodeId: UUID) -> String? {
        let content = readActiveEntryOrBlob(
            scope: .conversation,
            scopeRefId: nodeId,
            blobContent: { (try? nodeStore.fetchConversationMemory(nodeId: nodeId))?.content }
        )
        return Self.cap(content, budget: Self.conversationBudget)
    }

    /// Entry-first read with blob fallback. Trims and coerces empty → "".
    private func readActiveEntryOrBlob(
        scope: MemoryScope,
        scopeRefId: UUID?,
        blobContent: () -> String?
    ) -> String {
        if let entry = try? nodeStore.fetchActiveMemoryEntry(scope: scope, scopeRefId: scopeRefId) {
            let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return (blobContent() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when this project has accumulated `threshold` or more conversation
    /// refreshes since the last `refreshProject` (or ever, if the project has
    /// never been refreshed). Backed by `project_refresh_state.counter`, which
    /// increments once per successful conversation refresh and resets to 0
    /// after a project refresh. Counts EVENTS, not rows, so a single hot chat
    /// refreshed N times will correctly cross the threshold — the row-counting
    /// version confused `INSERT OR REPLACE` (one row per chat) with events.
    func shouldRefreshProject(projectId: UUID, threshold: Int) -> Bool {
        let count = (try? nodeStore.readProjectRefreshCounter(projectId: projectId)) ?? 0
        return count >= threshold
    }

    // MARK: - Write

    /// Called after each completed send. Summarises **only** Alex's user-role
    /// turns for this chat. Assistant turns are excluded to prevent the
    /// self-confirmation loop (Nous's own replies becoming next turn's evidence).
    ///
    /// Evidence filter is content-level, not just role-level: markdown quote
    /// blocks (`> …`) are stripped and any user turn whose remaining text is
    /// ≥60% similar to a prior assistant turn in the same conversation is
    /// dropped. This protects invariant #4 when Alex pastes Nous's reply back
    /// into his next message (a common clarification pattern).
    func refreshConversation(nodeId: UUID, projectId: UUID?, messages: [Message]) async {
        let priorAssistantTurns: [String] = messages
            .filter { $0.role == .assistant }
            .map { Self.stripQuoteBlocks($0.content) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let cleanedUserTurns: [String] = messages
            .filter { $0.role == .user }
            .compactMap { msg -> String? in
                let stripped = Self.stripQuoteBlocks(msg.content)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !stripped.isEmpty else { return nil }
                for prior in priorAssistantTurns {
                    if Self.tokenJaccard(stripped, prior) >= 0.6 {
                        return nil
                    }
                }
                return stripped
            }

        let userTurns = cleanedUserTurns
            .suffix(8)
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
                // Codex #2: cooperative cancel. When the scheduler cancels this
                // task because a newer enqueue arrived, stop consuming tokens
                // and skip the write so the fresher `messages` snapshot wins.
                if Task.isCancelled { return }
                updated += chunk
            }

            if Task.isCancelled { return }
            let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let now = Date()
            Self.logPersistenceErrors("saveConversationMemory") {
                try nodeStore.saveConversationMemory(
                    ConversationMemory(nodeId: nodeId, content: trimmed, updatedAt: now)
                )
            }
            // v2.2b dual-write: mirror the saved blob into memory_entries. Blob
            // write above is still the source of truth for v2.1 reads; entries
            // become the source of truth in v2.2c.
            writeScopeEntry(
                scope: .conversation,
                scopeRefId: nodeId,
                content: trimmed,
                kind: .thread,
                stability: .temporary,
                sourceNodeIds: [nodeId],
                now: now
            )
            if let projectId = projectId {
                Self.logPersistenceErrors("incrementProjectRefreshCounter") {
                    try nodeStore.incrementProjectRefreshCounter(projectId: projectId)
                }
            }
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
                if Task.isCancelled { return }
                updated += chunk
            }

            if Task.isCancelled { return }
            let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let now = Date()
            Self.logPersistenceErrors("saveProjectMemory") {
                try nodeStore.saveProjectMemory(
                    ProjectMemory(projectId: projectId, content: trimmed, updatedAt: now)
                )
            }
            writeScopeEntry(
                scope: .project,
                scopeRefId: projectId,
                content: trimmed,
                kind: .thread,
                stability: .stable,
                sourceNodeIds: [],
                now: now
            )
            Self.logPersistenceErrors("resetProjectRefreshCounter") {
                try nodeStore.resetProjectRefreshCounter(projectId: projectId)
            }
        } catch {
            return
        }
    }

    /// v1: invoked by the Memory Inspector UI when Alex explicitly promotes a
    /// project-level fact to identity level. v2 will auto-promote when the same
    /// fact recurs across ≥3 projects.
    ///
    /// PRECONDITION — Phase 3 ONLY. Do not call from Phase 1 / 1.5 code paths,
    /// tests that aren't exercising Phase 3, or any future auto-promote loop
    /// until Phase 3 ships edit-lock + dedup. This method does a read-modify-
    /// write on `global_memory` with no concurrency guard — two callers racing
    /// will silently clobber each other (and any in-progress user edit in the
    /// Memory Inspector). The Phase 3 Memory Inspector is the sole authorised
    /// caller; Phase 1.5's debug inspector is read-only and must never reach
    /// this path.
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
                if Task.isCancelled { return }
                updated += chunk
            }

            if Task.isCancelled { return }
            let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let now = Date()
            Self.logPersistenceErrors("saveGlobalMemory") {
                try nodeStore.saveGlobalMemory(
                    GlobalMemory(content: trimmed, updatedAt: now)
                )
            }
            writeScopeEntry(
                scope: .global,
                scopeRefId: nil,
                content: trimmed,
                kind: .identity,
                stability: .stable,
                sourceNodeIds: [],
                now: now
            )
        } catch {
            return
        }
    }

    // MARK: - v2.2b dual-write

    /// Mirror a freshly-saved scope blob into `memory_entries` so entries grow
    /// as a structured journal alongside v2.1's blob source-of-truth. Called
    /// after each successful `saveGlobalMemory` / `saveProjectMemory` /
    /// `saveConversationMemory`.
    ///
    /// **Invariant**: for every (scope, scopeRefId), at most one `active` entry
    /// at any moment. The older active (if any) is marked `superseded` and
    /// linked to the replacement via `supersededBy`, preserving evolution
    /// history. Wrapped in a single transaction so a crash mid-write can never
    /// leave two concurrent actives.
    ///
    /// **Parity property**: after this completes,
    /// `fetchActiveMemoryEntry(scope, scopeRefId).content == scope blob content`.
    /// v2.2b tests assert this invariant; v2.2c will use it to flip the read
    /// path from blob to entry without behavior change.
    ///
    /// Failures are swallowed (logged in DEBUG) — entries are a shadow index
    /// in v2.2b; a missing entry row must never crash a chat. Blob write above
    /// still holds the user-visible memory.
    private func writeScopeEntry(
        scope: MemoryScope,
        scopeRefId: UUID?,
        content: String,
        kind: MemoryKind,
        stability: MemoryStability,
        sourceNodeIds: [UUID],
        now: Date
    ) {
        let newEntry = MemoryEntry(
            scope: scope,
            scopeRefId: scopeRefId,
            kind: kind,
            stability: stability,
            content: content,
            sourceNodeIds: sourceNodeIds,
            createdAt: now,
            updatedAt: now,
            lastConfirmedAt: now
        )
        Self.logPersistenceErrors("writeScopeEntry(\(scope.rawValue))") {
            try nodeStore.inTransaction {
                try nodeStore.supersedeActiveMemoryEntries(
                    scope: scope,
                    scopeRefId: scopeRefId,
                    replacementId: newEntry.id,
                    at: now
                )
                try nodeStore.insertMemoryEntry(newEntry)
            }
        }
    }

    // MARK: - Helpers

    /// Removes markdown blockquote lines (`> …` or `>> …`) from content.
    /// Used to drop quoted assistant text that Alex pastes into his next turn.
    static func stripQuoteBlocks(_ content: String) -> String {
        content
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")
    }

    /// Jaccard similarity over lowercased whitespace-split tokens. Returns a
    /// value in [0.0, 1.0]. Short strings (<3 tokens) return 0 to avoid false
    /// positives from common words like "ok" / "thanks".
    static func tokenJaccard(_ a: String, _ b: String) -> Double {
        let tokensA = Set(a.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        let tokensB = Set(b.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        guard tokensA.count >= 3, tokensB.count >= 3 else { return 0 }
        let intersection = tokensA.intersection(tokensB).count
        let union = tokensA.union(tokensB).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    /// Codex #7: replaces `try?` for persistence writes. Silently swallowing
    /// SQLite failures means Alex's memory could stop being saved and he'd
    /// never know. We still don't rethrow (an occasional write failure must
    /// not crash a user-facing chat), but DEBUG builds log so the failure is
    /// visible while iterating locally. Prod is silent by design.
    static func logPersistenceErrors(_ label: String, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            #if DEBUG
            print("[UserMemoryService] \(label) failed: \(error)")
            #endif
        }
    }

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
