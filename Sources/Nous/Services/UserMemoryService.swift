import Foundation

/// Three-scope memory service (v2.1). Replaces the single global-blob refresh
/// with per-conversation / per-project / global layers. See
/// `.context/plans/cross-chat-memory-v2.md` §5 for the architecture.
final class UserMemoryService {

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

    private let nodeStore: NodeStore
    private let llmServiceProvider: () -> (any LLMService)?
    private let governanceTelemetry: GovernanceTelemetryStore?

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
