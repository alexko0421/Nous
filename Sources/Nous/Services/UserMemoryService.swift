import Foundation

/// Three-scope memory service (v2.1). Replaces the single global-blob refresh
/// with per-conversation / per-project / global layers. See
/// `.context/plans/cross-chat-memory-v2.md` §5 for the architecture.
final class UserMemoryCore {

    enum PersonalInferenceDisposition {
        case unconfirmed
        case confirmed
        case repeatedEvidence
        case rejected
    }

    // Per-layer token budgets from plan §6. Cap at read time so the database
    // can hold longer content if needed but the prompt stays bounded.
    static let globalBudget = 600
    static let essentialStoryBudget = 500
    static let projectBudget = 400
    static let conversationBudget = 200
    static let evidenceSnippetBudget = 180
    static let userModelFacetLimit = 3
    static let contradictionFactKinds: [MemoryKind] = [.decision, .boundary, .constraint]

    private let nodeStore: NodeStore
    private let llmServiceProvider: () -> (any LLMService)?
    private let governanceTelemetry: GovernanceTelemetryStore?

    struct AnnotatedContradictionFact: Equatable {
        let fact: MemoryFactEntry
        let isContradictionCandidate: Bool
        let relevanceScore: Double
    }

    init(
        nodeStore: NodeStore,
        llmServiceProvider: @escaping () -> (any LLMService)?,
        governanceTelemetry: GovernanceTelemetryStore? = nil
    ) {
        self.nodeStore = nodeStore
        self.llmServiceProvider = llmServiceProvider
        self.governanceTelemetry = governanceTelemetry
    }

    // MARK: - Read (used by ChatViewModel.assembleContext)

    /// v2.2d: reads come exclusively from `memory_entries`. The v2.1 blob
    /// fallback from v2.2c is gone — entries are now the sole source of truth.
    /// Pre-v2.2 blobs are still read once by `MemoryEntriesMigrator` at first
    /// boot to seed the entries table; after that, blobs are frozen and never
    /// touched.
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

    /// Derived "wake-up" layer between stable identity and scoped/project
    /// memory. This is intentionally not a second canonical store — it is a
    /// bounded blend of current project context and recent live threads, with
    /// one stable backdrop line from global memory when available.
    func currentEssentialStory(
        projectId: UUID?,
        excludingConversationId: UUID? = nil
    ) -> String? {
        let globalMemory = readActiveEntry(scope: .global, scopeRefId: nil)

        var projectTitle: String?
        var projectMemory: String = ""
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

    /// Selects a tiny amount of raw supporting evidence for the memory layers
    /// most likely to matter in the current turn. This keeps the prompt
    /// grounded without dumping large transcript blocks back into context.
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

    func shouldPersistMemory(messages: [Message], projectId: UUID?) -> Bool {
        guard let latestUserMessage = messages.reversed().first(where: { $0.role == .user }) else {
            return true
        }

        let latestContent = Self.stripQuoteBlocks(latestUserMessage.content)
        if SafetyGuardrails.containsHardMemoryOptOut(latestContent) {
            return false
        }

        let boundaries = currentMemoryBoundary(projectId: projectId)
        if SafetyGuardrails.requiresConsentForSensitiveMemory(boundaryLines: boundaries),
           SafetyGuardrails.containsSensitiveMemory(latestContent) {
            return false
        }

        return true
    }

    func allMemoryEntries() -> [MemoryEntry] {
        ((try? nodeStore.fetchMemoryEntries()) ?? [])
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    func sourceSnippets(for entryId: UUID, limit: Int = 3) -> [MemoryEvidenceSnippet] {
        guard limit > 0,
              let entry = try? nodeStore.fetchMemoryEntry(id: entryId) else {
            return []
        }

        var snippets: [MemoryEvidenceSnippet] = []
        var usedSourceNodeIds: Set<UUID> = []

        for sourceNodeId in dedupeSourceNodeIds(entry.sourceNodeIds) {
            guard !usedSourceNodeIds.contains(sourceNodeId) else { continue }
            guard let node = try? nodeStore.fetchNode(id: sourceNodeId) else { continue }
            let snippet = extractEvidenceSnippet(from: node)
            guard !snippet.isEmpty else { continue }

            usedSourceNodeIds.insert(sourceNodeId)
            snippets.append(
                MemoryEvidenceSnippet(
                    label: scopeLabel(for: entry.scope),
                    sourceNodeId: sourceNodeId,
                    sourceTitle: node.title.isEmpty ? "Untitled" : node.title,
                    snippet: snippet
                )
            )

            if snippets.count == limit { break }
        }

        return snippets
    }

    @discardableResult
    func confirmMemoryEntry(id: UUID) -> Bool {
        let didMutate = mutateMemoryEntry(id: id) { entry in
            guard entry.status == .active else { return false }
            let now = Date()
            entry.updatedAt = now
            entry.lastConfirmedAt = now
            entry.confidence = max(entry.confidence, entry.stability == .stable ? 0.95 : 0.9)
            return true
        }
        if didMutate {
            governanceTelemetry?.increment(.memoryPrecision)
        }
        return didMutate
    }

    @discardableResult
    func archiveMemoryEntry(id: UUID) -> Bool {
        mutateMemoryEntry(id: id) { entry in
            guard entry.status != .archived else { return false }
            entry.status = .archived
            entry.updatedAt = Date()
            return true
        }
    }

    @discardableResult
    func deleteMemoryEntry(id: UUID) -> Bool {
        do {
            try nodeStore.deleteMemoryEntry(id: id)
            return true
        } catch {
            #if DEBUG
            print("[UserMemoryService] deleteMemoryEntry failed: \(error)")
            #endif
            return false
        }
    }

    /// Returns the active entry's content trimmed, or "" if no active entry.
    private func readActiveEntry(scope: MemoryScope, scopeRefId: UUID?) -> String {
        guard let entry = try? nodeStore.fetchActiveMemoryEntry(scope: scope, scopeRefId: scopeRefId) else {
            return ""
        }
        return entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Returns active contradiction-oriented facts that are currently in scope
    /// for this conversation. Scope priority is conversation -> project ->
    /// global so narrower facts win if identical content exists at multiple
    /// scopes. `temporary` stability is not filtered out in Phase 1.
    func contradictionRecallFacts(projectId: UUID?, conversationId: UUID) throws -> [MemoryFactEntry] {
        var facts: [MemoryFactEntry] = []
        facts.append(contentsOf: try nodeStore.fetchActiveMemoryFactEntries(
            scope: .conversation,
            scopeRefId: conversationId,
            kinds: Self.contradictionFactKinds
        ))
        if let projectId {
            facts.append(contentsOf: try nodeStore.fetchActiveMemoryFactEntries(
                scope: .project,
                scopeRefId: projectId,
                kinds: Self.contradictionFactKinds
            ))
        }
        facts.append(contentsOf: try nodeStore.fetchActiveMemoryFactEntries(
            scope: .global,
            scopeRefId: nil,
            kinds: Self.contradictionFactKinds
        ))
        return Self.dedupedFactEntries(facts)
    }

    /// Marks the top in-pool contradiction candidates for a future judge
    /// prompt. Uses relative ranking only; if nothing has any lexical overlap
    /// with the current message, nothing is marked.
    func annotateContradictionCandidates(
        currentMessage: String,
        facts: [MemoryFactEntry],
        maxCandidates: Int = 3
    ) -> [AnnotatedContradictionFact] {
        guard maxCandidates > 0, !facts.isEmpty else {
            return facts.map {
                AnnotatedContradictionFact(fact: $0, isContradictionCandidate: false, relevanceScore: 0)
            }
        }

        let scored: [(index: Int, score: Double)] = facts.enumerated().map { offset, fact in
            (index: offset, score: Self.tokenJaccard(currentMessage, fact.content))
        }

        let candidateIndexes = Set(
            scored
                .filter { $0.score > 0 }
                .sorted { lhs, rhs in
                    if lhs.score == rhs.score {
                        return facts[lhs.index].updatedAt > facts[rhs.index].updatedAt
                    }
                    return lhs.score > rhs.score
                }
                .prefix(maxCandidates)
                .map(\.index)
        )

        return facts.enumerated().map { offset, fact in
            AnnotatedContradictionFact(
                fact: fact,
                isContradictionCandidate: candidateIndexes.contains(offset),
                relevanceScore: scored[offset].score
            )
        }
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

        let assistantMessages = messages.filter { $0.role == .assistant }
        let signaturePhrases = Self.extractSignatureMoments(from: assistantMessages)
        let signatureMomentsBlock: String
        if signaturePhrases.isEmpty {
            signatureMomentsBlock = "[none]"
        } else {
            signatureMomentsBlock = signaturePhrases
                .map { "- \"\($0)\"" }
                .joined(separator: "\n")
        }
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

        Signature moments flagged by Nous earlier in this conversation (text-only quotes — no Nous prose, so the self-confirmation guard is preserved; preservation-critical — MUST appear verbatim in a bullet, quoted in 「」):
        \(signatureMomentsBlock)

        IMAGERY PRESERVATION:
        - Every phrase in the signature moments list above MUST appear verbatim in a bullet (quote in 「」). If the list is [none], skip this rule.
        - When Alex's turns contain specific details (concrete numbers, objects, sensory imagery), an original metaphor, or non-obvious phrasing, preserve that specificity. Do NOT substitute abstract categories.
        - For other concrete imagery (not flagged), paraphrase with specifics — keep the vivid detail, not just the abstract pattern.
        - Generic content (routine Q&A, acknowledgments) compresses normally.

        PRIORITY: Preserve imagery > hit bullet count.

        Bullet budget: up to 8 bullets. Prefer fewer when content allows, but extend to 8 before flattening imagery.

        EXAMPLE PAIRS — study the difference between flat ❌ and texture-preserving ✅:

        1. Idea-exploration:
           ❌ 品味 = 基于大量经验同失败而建立起嚟嘅判断系统
           ✅ 品味 = 「睇过一千幅画，试过一百种咖啡，失败过十次」之后形成嘅 judgment

        2. Problem-solving:
           ❌ 修复咗 authentication 嘅 bug
           ✅ 修咗 login bug：session cookie 响 Safari 被当作 third-party，改咗 SameSite=Lax 之后 work

        3. Emotional-processing:
           ❌ Alex 处理紧关于工作嘅挫败感
           ✅ Alex 讲：「我觉得自己系响隧道入面跑，但冇人话我终点响边」——感到 direction 缺失

        4. Planning:
           ❌ 讨论咗下季度嘅优先事项
           ✅ 决定 Q2 聚焦 retention 而非 growth，理由：「先把漏斗底补实，再落更多水」

        5. Teaching / learning:
           ❌ 学咗点用 Swift concurrency
           ✅ Aha: async let 同 TaskGroup 嘅分别——「async let 系兵，TaskGroup 系将」

        6. Venting:
           ❌ 对 meeting overload 感到 frustration
           ✅ Alex 讲：「我嘅 calendar 系别人 agenda 嘅投影」——冇 mental space 做 deep work

        7. Abstract vs concrete (general):
           ❌ Alex describe 咗一个复杂嘅想法
           ✅ Alex describe：思考就系「响脑入面开咗十个 tab，但闩唔到其中任何一个」

        8. Routine (not every turn needs preservation):
           ❌ Alex 问问题、得到答案
           ✅ Alex 问点 set up Xcode scheme（basic dev question，唔需要特别 preserve）

        Markdown only.
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
            // v2.2d: entry-only write. The v2.1 conversation_memory blob is
            // frozen at its v2.2b-migration snapshot; we no longer dual-write
            // it. Entries are now the sole source of truth.
            writeScopeEntry(
                scope: .conversation,
                scopeRefId: nodeId,
                content: trimmed,
                kind: .thread,
                stability: .temporary,
                sourceNodeIds: [nodeId],
                now: now
            )
            await refreshConversationFacts(
                nodeId: nodeId,
                userTurns: userTurns,
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

    /// Aggregates all active conversation memory_entries for nodes in this
    /// project into a single project-level rollup. Called by
    /// `UserMemoryScheduler` on a counter cadence (every N conversation
    /// refreshes in the same project).
    ///
    /// v2.2d: aggregation reads from `memory_entries` (active conversation
    /// rows) instead of the frozen v2.1 `conversation_memory` blob.
    func refreshProject(projectId: UUID) async {
        guard let nodes = try? nodeStore.fetchNodes(projectId: projectId) else { return }

        var projectSourceNodeIds: [UUID] = []
        var seenSourceNodeIds: Set<UUID> = []
        let convoBlobs = nodes.compactMap { node -> String? in
            guard let entry = try? nodeStore.fetchActiveMemoryEntry(
                scope: .conversation, scopeRefId: node.id
            ) else {
                return nil
            }
            let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let sourceIds = entry.sourceNodeIds.isEmpty ? [node.id] : entry.sourceNodeIds
            for sourceId in sourceIds where seenSourceNodeIds.insert(sourceId).inserted {
                projectSourceNodeIds.append(sourceId)
            }
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
            // v2.2d: entry-only write.
            writeScopeEntry(
                scope: .project,
                scopeRefId: projectId,
                content: trimmed,
                kind: .thread,
                stability: .stable,
                sourceNodeIds: projectSourceNodeIds,
                now: now
            )
            refreshProjectFacts(projectId: projectId, nodes: nodes, now: now)
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
    func promoteToGlobal(
        candidate: String,
        sourceNodeIds: [UUID] = [],
        confirmation: PersonalInferenceDisposition = .unconfirmed
    ) async -> Bool {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidate.isEmpty else { return false }

        let dedupedSourceNodeIds = dedupeSourceNodeIds(sourceNodeIds)
        switch confirmation {
        case .unconfirmed:
            return false
        case .rejected:
            rejectGlobalCandidate(trimmedCandidate)
            return false
        case .repeatedEvidence:
            guard dedupedSourceNodeIds.count >= 2 else { return false }
        case .confirmed:
            break
        }

        guard let llm = llmServiceProvider() else { return false }

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
                if Task.isCancelled { return false }
                updated += chunk
            }

            if Task.isCancelled { return false }
            let trimmed = updated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            let now = Date()
            // v2.2d: entry-only write.
            writeScopeEntry(
                scope: .global,
                scopeRefId: nil,
                content: trimmed,
                kind: .identity,
                stability: .stable,
                sourceNodeIds: dedupedSourceNodeIds,
                confidence: confirmation == .confirmed ? 0.95 : 0.85,
                lastConfirmedAt: now,
                now: now
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Canonical scope writes

    /// Persist the latest scope summary into canonical `memory_entries`.
    /// One active entry exists per `(scope, scopeRefId)`; older actives are
    /// superseded and linked via `supersededBy` so the evolution chain stays
    /// inspectable. Wrapped in one transaction so the read path never sees two
    /// concurrent actives for the same scope.
    ///
    /// Failures are swallowed (logged in DEBUG) because an occasional memory
    /// write failure should not crash a user-facing chat.
    private func writeScopeEntry(
        scope: MemoryScope,
        scopeRefId: UUID?,
        content: String,
        kind: MemoryKind,
        stability: MemoryStability,
        sourceNodeIds: [UUID],
        confidence: Double = 0.8,
        lastConfirmedAt: Date? = nil,
        now: Date
    ) {
        let newEntry = MemoryEntry(
            scope: scope,
            scopeRefId: scopeRefId,
            kind: kind,
            stability: stability,
            content: content,
            confidence: confidence,
            sourceNodeIds: sourceNodeIds,
            createdAt: now,
            updatedAt: now,
            lastConfirmedAt: lastConfirmedAt ?? now
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

    private func mutateMemoryEntry(
        id: UUID,
        transform: (inout MemoryEntry) -> Bool
    ) -> Bool {
        guard var entry = try? nodeStore.fetchMemoryEntry(id: id) else {
            return false
        }
        guard transform(&entry) else { return false }
        do {
            try nodeStore.updateMemoryEntry(entry)
            return true
        } catch {
            #if DEBUG
            print("[UserMemoryService] mutateMemoryEntry failed: \(error)")
            #endif
            return false
        }
    }

    private func rejectGlobalCandidate(_ candidate: String) {
        guard var activeEntry = try? nodeStore.fetchActiveMemoryEntry(scope: .global, scopeRefId: nil) else {
            return
        }
        guard contentReferencesCandidate(activeEntry.content, candidate: candidate) else { return }

        activeEntry.status = .conflicted
        activeEntry.confidence = min(activeEntry.confidence, 0.2)
        activeEntry.lastConfirmedAt = nil
        activeEntry.updatedAt = Date()

        Self.logPersistenceErrors("rejectGlobalCandidate") {
            try nodeStore.updateMemoryEntry(activeEntry)
        }
        governanceTelemetry?.increment(.overInferenceRate)
    }

    private func contentReferencesCandidate(_ content: String, candidate: String) -> Bool {
        let normalizedCandidate = Self.normalizedLine(candidate)
        guard !normalizedCandidate.isEmpty else { return false }

        if Self.normalizedLine(content).contains(normalizedCandidate) {
            return true
        }

        return Self.extractSummaryLines(from: content, limit: 12).contains { line in
            let normalizedLine = Self.normalizedLine(line)
            return normalizedLine.contains(normalizedCandidate)
                || normalizedCandidate.contains(normalizedLine)
                || Self.tokenJaccard(normalizedLine, normalizedCandidate) >= 0.6
        }
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

        for line in Self.extractSummaryLines(from: node.content, limit: 1) {
            if !line.isEmpty {
                return Self.preview(line, maxChars: Self.evidenceSnippetBudget)
            }
        }

        return Self.preview(node.content, maxChars: Self.evidenceSnippetBudget)
    }

    private func scopeLabel(for scope: MemoryScope) -> String {
        switch scope {
        case .global:
            return "Global memory"
        case .project:
            return "Project memory"
        case .conversation:
            return "Thread memory"
        case .selfReflection:
            return "Self-reflection"
        }
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

    private struct ExtractedFactPayload: Decodable {
        let kind: String
        let content: String
        let confidence: Double?
    }

    private struct ExtractedFactEnvelope: Decodable {
        let facts: [ExtractedFactPayload]
    }

    private func refreshConversationFacts(
        nodeId: UUID,
        userTurns: String,
        now: Date
    ) async {
        guard let llm = llmServiceProvider() else { return }

        let existingBlock = activeFactBlock(scope: .conversation, scopeRefId: nodeId)
        let prompt = """
        Existing contradiction-oriented facts for this chat:
        \(existingBlock)

        Recent things Alex said (ALEX ONLY — Nous's replies are intentionally omitted to avoid self-confirmation loops):
        \(userTurns)

        Return a JSON array of the currently active contradiction-oriented facts for this chat.
        Each item must be:
        {"kind":"decision|boundary|constraint","content":"...","confidence":0.0-1.0}

        Rules:
        - decision = an explicit choice Alex made
        - boundary = a red line, do-not-cross rule, or operating principle
        - constraint = a real limitation or non-negotiable condition
        - Only keep facts Alex himself said or clearly implied
        - Only keep facts that still seem active for this chat
        - If there are none, return []
        - JSON only. No Markdown, no commentary
        """

        do {
            let stream = try await llm.generate(
                messages: [LLMMessage(role: "user", content: prompt)],
                system: """
                You extract contradiction-oriented memory facts for Nous.
                Allowed kinds: decision, boundary, constraint.
                Never emit identity, preference, relationship, or thread summaries.
                Return strict JSON only.
                """
            )

            var raw = ""
            for try await chunk in stream {
                if Task.isCancelled { return }
                raw += chunk
            }

            if Task.isCancelled { return }

            let facts = try Self.decodeFactPayloads(raw).map {
                MemoryFactEntry(
                    scope: .conversation,
                    scopeRefId: nodeId,
                    kind: $0.kind,
                    content: $0.content,
                    confidence: $0.confidence,
                    status: .active,
                    stability: .stable,
                    sourceNodeIds: [nodeId],
                    createdAt: now,
                    updatedAt: now
                )
            }
            replaceActiveFacts(
                scope: .conversation,
                scopeRefId: nodeId,
                with: facts,
                now: now
            )
        } catch {
            return
        }
    }

    private func refreshProjectFacts(
        projectId: UUID,
        nodes: [NousNode],
        now: Date
    ) {
        var conversationFacts: [MemoryFactEntry] = []
        for node in nodes where node.type == .conversation {
            guard let facts = try? nodeStore.fetchActiveMemoryFactEntries(
                scope: .conversation,
                scopeRefId: node.id,
                kinds: Self.contradictionFactKinds
            ) else {
                continue
            }
            conversationFacts.append(contentsOf: facts)
        }

        let projectFacts = Self.rollUpProjectFacts(
            projectId: projectId,
            conversationFacts: conversationFacts,
            now: now
        )
        replaceActiveFacts(
            scope: .project,
            scopeRefId: projectId,
            with: projectFacts,
            now: now
        )
    }

    private func replaceActiveFacts(
        scope: MemoryScope,
        scopeRefId: UUID?,
        with entries: [MemoryFactEntry],
        now: Date
    ) {
        Self.logPersistenceErrors("replaceActiveFacts(\(scope.rawValue))") {
            try nodeStore.inTransaction {
                let existing = try nodeStore.fetchActiveMemoryFactEntries(
                    scope: scope,
                    scopeRefId: scopeRefId,
                    kinds: Self.contradictionFactKinds
                )
                for var fact in existing {
                    fact.status = .archived
                    fact.updatedAt = now
                    try nodeStore.updateMemoryFactEntry(fact)
                }
                for entry in Self.dedupedFactEntries(entries) {
                    try nodeStore.insertMemoryFactEntry(entry)
                }
            }
        }
    }

    private func activeFactBlock(scope: MemoryScope, scopeRefId: UUID?) -> String {
        guard let facts = try? nodeStore.fetchActiveMemoryFactEntries(
            scope: scope,
            scopeRefId: scopeRefId,
            kinds: Self.contradictionFactKinds
        ), !facts.isEmpty else {
            return "[]"
        }

        let lines = facts.map { fact in
            "- [\(fact.kind.rawValue)] \(fact.content) (confidence: \(String(format: "%.2f", fact.confidence)))"
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Removes markdown blockquote lines (`> …` or `>> …`) from content.
    /// Used to drop quoted assistant text that Alex pastes into his next turn.
    static func extractSignatureMoments(from assistantMessages: [Message]) -> [String] {
        let blockPattern = #"<signature_moments>([\s\S]*?)</signature_moments>"#
        let textPattern = #"text:\s*"([^"]*)""#

        guard
            let blockRegex = try? NSRegularExpression(pattern: blockPattern),
            let textRegex = try? NSRegularExpression(pattern: textPattern)
        else {
            return []
        }

        var phrases: [String] = []
        for message in assistantMessages {
            let content = message.content
            let range = NSRange(content.startIndex..., in: content)
            let blockMatches = blockRegex.matches(in: content, range: range)
            for blockMatch in blockMatches {
                guard blockMatch.numberOfRanges >= 2,
                      let inner = Range(blockMatch.range(at: 1), in: content) else { continue }
                let body = String(content[inner])
                let bodyRange = NSRange(body.startIndex..., in: body)
                let textMatches = textRegex.matches(in: body, range: bodyRange)
                for textMatch in textMatches {
                    guard textMatch.numberOfRanges >= 2,
                          let textRange = Range(textMatch.range(at: 1), in: body) else { continue }
                    let phrase = String(body[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !phrase.isEmpty {
                        phrases.append(phrase)
                    }
                }
            }
        }
        return phrases
    }

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

    private static func decodeFactPayloads(_ raw: String) throws -> [(kind: MemoryKind, content: String, confidence: Double)] {
        let decoder = JSONDecoder()
        let cleaned = stripJSONCodeFence(raw)
        guard let data = cleaned.data(using: .utf8) else {
            throw LLMError.invalidResponse
        }

        let payloads: [ExtractedFactPayload]
        if let direct = try? decoder.decode([ExtractedFactPayload].self, from: data) {
            payloads = direct
        } else if let wrapped = try? decoder.decode(ExtractedFactEnvelope.self, from: data) {
            payloads = wrapped.facts
        } else {
            throw LLMError.invalidResponse
        }

        return payloads.compactMap { payload in
            guard let kind = contradictionFactKind(from: payload.kind) else { return nil }
            let content = payload.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return (
                kind: kind,
                content: content,
                confidence: clampConfidence(payload.confidence ?? 0.8)
            )
        }
    }

    private static func contradictionFactKind(from raw: String) -> MemoryKind? {
        guard let kind = MemoryKind(rawValue: raw.lowercased()) else { return nil }
        guard contradictionFactKinds.contains(kind) else { return nil }
        return kind
    }

    private static func clampConfidence(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    private static func stripJSONCodeFence(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }

        var lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return trimmed }
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rollUpProjectFacts(
        projectId: UUID,
        conversationFacts: [MemoryFactEntry],
        now: Date
    ) -> [MemoryFactEntry] {
        var merged: [String: MemoryFactEntry] = [:]
        var order: [String] = []

        for fact in conversationFacts where contradictionFactKinds.contains(fact.kind) {
            let key = factKey(kind: fact.kind, content: fact.content)
            if var existing = merged[key] {
                existing.confidence = max(existing.confidence, fact.confidence)
                existing.sourceNodeIds = Array(Set(existing.sourceNodeIds).union(fact.sourceNodeIds))
                existing.updatedAt = now
                merged[key] = existing
                continue
            }

            merged[key] = MemoryFactEntry(
                scope: .project,
                scopeRefId: projectId,
                kind: fact.kind,
                content: fact.content,
                confidence: fact.confidence,
                status: .active,
                stability: .stable,
                sourceNodeIds: fact.sourceNodeIds,
                createdAt: now,
                updatedAt: now
            )
            order.append(key)
        }

        return order.compactMap { merged[$0] }
    }

    private static func dedupedFactEntries(_ entries: [MemoryFactEntry]) -> [MemoryFactEntry] {
        var merged: [String: MemoryFactEntry] = [:]
        var order: [String] = []

        for entry in entries where contradictionFactKinds.contains(entry.kind) {
            let key = factKey(kind: entry.kind, content: entry.content)
            if var existing = merged[key] {
                existing.confidence = max(existing.confidence, entry.confidence)
                existing.sourceNodeIds = Array(Set(existing.sourceNodeIds).union(entry.sourceNodeIds))
                existing.updatedAt = max(existing.updatedAt, entry.updatedAt)
                merged[key] = existing
                continue
            }
            merged[key] = entry
            order.append(key)
        }

        return order.compactMap { merged[$0] }
    }

    private static func factKey(kind: MemoryKind, content: String) -> String {
        let normalized = content
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return "\(kind.rawValue)|\(normalized)"
    }
}

extension UserMemoryCore {

    /// Returns the entries the judge may cite this turn. Phase 1 prepends
    /// contradiction-oriented hard-recall facts, then falls back to the existing
    /// node-hit bridging + recency seed path for raw `memory_entries`.
    func citableEntryPool(
        projectId: UUID?,
        conversationId: UUID,
        nodeHits: [UUID],
        hardRecallFacts: [MemoryFactEntry] = [],
        contradictionCandidateIds: Set<String> = [],
        capacity: Int = 15,
        recencySeedPerScope: Int = 3,
        reflectionSeed: Int = 2
    ) throws -> [CitableEntry] {
        var seen = Set<String>()
        var out: [CitableEntry] = []

        func admit(_ entry: CitableEntry) {
            guard out.count < capacity else { return }
            guard seen.insert(entry.id).inserted else { return }
            out.append(entry)
        }

        func admit(_ entry: MemoryEntry) {
            guard isInScope(entry, projectId: projectId, conversationId: conversationId) else { return }
            admit(CitableEntry(
                id: entry.id.uuidString,
                text: entry.content,
                scope: entry.scope,
                kind: entry.kind
            ))
        }

        func admit(_ fact: MemoryFactEntry) {
            guard isInScope(fact, projectId: projectId, conversationId: conversationId) else { return }
            admit(CitableEntry(
                id: fact.id.uuidString,
                text: fact.content,
                scope: fact.scope,
                kind: fact.kind,
                promptAnnotation: contradictionCandidateIds.contains(fact.id.uuidString) ? "contradiction-candidate" : nil
            ))
        }

        // Pass 1 — hard recall facts the judge must always see if they are in scope.
        hardRecallFacts.forEach(admit)

        // Pass 2 — node-hit bridging from the main vector retrieval.
        for hit in nodeHits where out.count < capacity {
            let bridged = (try? nodeStore.fetchMemoryEntries(withSourceNodeId: hit)) ?? []
            for entry in bridged {
                admit(entry)
                if out.count >= capacity { break }
            }
        }

        // Pass 3 — weekly self-reflection claims. Reserved slots before
        // ambient recency so the judge can anchor a provocation on a pattern
        // observed across last week's conversations. Capped at
        // `reflectionSeed` (default 2, matching per-week production) so older
        // weeks don't crowd out the freshest read. Scope-safe: free-chat
        // (projectId=nil) matches NULL-projectId reflection rows.
        if reflectionSeed > 0 && out.count < capacity {
            let reflections = (try? nodeStore.fetchActiveReflectionClaims(projectId: projectId)) ?? []
            for claim in reflections.prefix(reflectionSeed) {
                admit(CitableEntry(
                    id: claim.id.uuidString,
                    text: claim.claim,
                    scope: .selfReflection,
                    kind: nil,
                    promptAnnotation: "weekly-reflection"
                ))
                if out.count >= capacity { break }
            }
        }

        // Pass 4 — recency seed per active scope.
        let globalRecent = (try? fetchRecentEntries(scope: .global, scopeRefId: nil, limit: recencySeedPerScope)) ?? []
        globalRecent.forEach(admit)

        if let projectId, out.count < capacity {
            let projectRecent = (try? fetchRecentEntries(scope: .project, scopeRefId: projectId, limit: recencySeedPerScope)) ?? []
            projectRecent.forEach(admit)
        }

        if out.count < capacity {
            let conversationRecent = (try? fetchRecentEntries(scope: .conversation, scopeRefId: conversationId, limit: recencySeedPerScope)) ?? []
            conversationRecent.forEach(admit)
        }

        return Array(out.prefix(capacity))
    }

    private func isInScope(_ entry: MemoryEntry, projectId: UUID?, conversationId: UUID) -> Bool {
        switch entry.scope {
        case .global:
            return true
        case .project:
            return entry.scopeRefId == projectId
        case .conversation:
            return entry.scopeRefId == conversationId
        case .selfReflection:
            // Reflections live in `reflection_claim`, never in `memory_entries`.
            // Compiler requires the case; at runtime this path is unreachable.
            return false
        }
    }

    private func isInScope(_ fact: MemoryFactEntry, projectId: UUID?, conversationId: UUID) -> Bool {
        switch fact.scope {
        case .global:
            return true
        case .project:
            return fact.scopeRefId == projectId
        case .conversation:
            return fact.scopeRefId == conversationId
        case .selfReflection:
            return false
        }
    }

    private func fetchRecentEntries(scope: MemoryScope, scopeRefId: UUID?, limit: Int) throws -> [MemoryEntry] {
        ((try? nodeStore.fetchMemoryEntries()) ?? [])
            .filter { $0.status == .active && $0.scope == scope && $0.scopeRefId == scopeRefId }
            .prefix(limit)
            .map { $0 }
    }
}
