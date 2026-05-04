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

    static let contradictionFactKinds: [MemoryKind] = [.decision, .boundary, .constraint]
    private static let evidenceTimestampFormatter = ISO8601DateFormatter()

    private let nodeStore: NodeStore
    private let llmServiceProvider: () -> (any LLMService)?
    private let governanceTelemetry: GovernanceTelemetryStore?
    private let embedFunction: (String) -> [Float]?

    struct AnnotatedContradictionFact: Equatable {
        let fact: MemoryFactEntry
        let isContradictionCandidate: Bool
        let relevanceScore: Double
    }

    private struct EvidencePromptTurn {
        let message: Message
        let previousAssistantQuestion: String?
        let protectedFragments: [String]
        let isHardOptOut: Bool
    }

    private struct MemoryPrivacyGuard {
        static let redactedEvidenceLine = "[memory_boundary_redacted] Alex explicitly marked a specific detail as do-not-remember. The detail is intentionally redacted; only the boundary may be remembered."
        static let redactedFragment = "[redacted do-not-remember detail]"

        let protectedFragments: [String]
        let optOutMessageIds: Set<UUID>

        var isEmpty: Bool {
            protectedFragments.isEmpty && optOutMessageIds.isEmpty
        }

        func redact(_ content: String) -> String {
            guard !protectedFragments.isEmpty else { return content }
            var redacted = content
            for fragment in protectedFragments {
                redacted = Self.replacing(fragment, in: redacted, with: Self.redactedFragment)
            }
            return redacted
        }

        func referencesProtectedContent(_ content: String) -> Bool {
            protectedFragments.contains { fragment in
                content.range(of: fragment, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }

        func blocks(sourceMessageId: UUID?) -> Bool {
            guard let sourceMessageId else { return false }
            return optOutMessageIds.contains(sourceMessageId)
        }

        private static func replacing(_ fragment: String, in content: String, with replacement: String) -> String {
            guard !fragment.isEmpty else { return content }
            var result = content
            while let range = result.range(of: fragment, options: [.caseInsensitive, .diacriticInsensitive]) {
                result.replaceSubrange(range, with: replacement)
            }
            return result
        }
    }

    init(
        nodeStore: NodeStore,
        llmServiceProvider: @escaping () -> (any LLMService)?,
        governanceTelemetry: GovernanceTelemetryStore? = nil,
        embedFunction: @escaping (String) -> [Float]? = { _ in nil }
    ) {
        self.nodeStore = nodeStore
        self.llmServiceProvider = llmServiceProvider
        self.governanceTelemetry = governanceTelemetry
        self.embedFunction = embedFunction
    }

    private var projectionReader: MemoryProjectionService {
        MemoryProjectionService(nodeStore: nodeStore)
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

    func factSourceSnippets(for factId: UUID, limit: Int = 3) -> [MemoryEvidenceSnippet] {
        guard limit > 0,
              let fact = try? nodeStore.fetchMemoryFactEntry(id: factId) else {
            return []
        }

        var snippets: [MemoryEvidenceSnippet] = []
        var usedSourceNodeIds: Set<UUID> = []

        for sourceNodeId in dedupeSourceNodeIds(fact.sourceNodeIds) {
            guard !usedSourceNodeIds.contains(sourceNodeId) else { continue }
            guard let node = try? nodeStore.fetchNode(id: sourceNodeId) else { continue }
            let snippet = extractEvidenceSnippet(from: node)
            guard !snippet.isEmpty else { continue }

            usedSourceNodeIds.insert(sourceNodeId)
            snippets.append(
                MemoryEvidenceSnippet(
                    label: scopeLabel(for: fact.scope),
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

    @discardableResult
    func confirmMemoryFactEntry(id: UUID) -> Bool {
        mutateMemoryFactEntry(id: id) { fact in
            guard fact.status == .active else { return false }
            fact.updatedAt = Date()
            fact.confidence = max(fact.confidence, fact.stability == .stable ? 0.95 : 0.9)
            return true
        }
    }

    @discardableResult
    func archiveMemoryFactEntry(id: UUID) -> Bool {
        mutateMemoryFactEntry(id: id) { fact in
            guard fact.status != .archived else { return false }
            fact.status = .archived
            fact.updatedAt = Date()
            return true
        }
    }

    @discardableResult
    func deleteMemoryFactEntry(id: UUID) -> Bool {
        do {
            try nodeStore.deleteMemoryFactEntry(id: id)
            return true
        } catch {
            #if DEBUG
            print("[UserMemoryService] deleteMemoryFactEntry failed: \(error)")
            #endif
            return false
        }
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
        let recentEvidenceTurns = Array(Self.cleanedEvidenceTurns(from: messages).suffix(8))
        let privacyGuard = Self.memoryPrivacyGuard(from: recentEvidenceTurns)
        let userTurns = Self.evidencePromptTurns(from: recentEvidenceTurns)

        guard !userTurns.isEmpty else { return }
        guard let llm = llmServiceProvider() else { return }

        let existing = privacyGuard.redact(projectionReader.currentConversation(nodeId: nodeId) ?? "")
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
        - Preserve temporal state exactly: planned/future/waiting actions must stay
          planned/future/waiting, not be rewritten as completed events.
        - Preserve exact price, currency, country, city, store, and availability
          wording. If Alex says "$220" or "两百二十蚊", do not rewrite it as
          HKD/USD/CNY unless he said that unit.
        - If a line includes [previous_nous_question_context_only], use it only
          to resolve what Alex's short reply refers to. Do not treat Nous context as source evidence or persist it unless Alex's reply confirms it.
        - If a short reply remains ambiguous, mark it as unclear instead of
          choosing the most likely interpretation.
        - If Alex gives a latest correction or says Nous misunderstood, the latest
          correction overrides existing thread memory and earlier ambiguous phrasing.
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
            let trimmed = privacyGuard.redact(updated).trimmingCharacters(in: .whitespacesAndNewlines)
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
                evidenceTurns: recentEvidenceTurns,
                privacyGuard: privacyGuard,
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
        let existing = projectionReader.currentProject(projectId: projectId) ?? ""
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

        let existing = projectionReader.currentGlobal() ?? ""
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

    private func mutateMemoryFactEntry(
        id: UUID,
        transform: (inout MemoryFactEntry) -> Bool
    ) -> Bool {
        guard var fact = try? nodeStore.fetchMemoryFactEntry(id: id) else {
            return false
        }
        guard transform(&fact) else { return false }
        do {
            try nodeStore.updateMemoryFactEntry(fact)
            return true
        } catch {
            #if DEBUG
            print("[UserMemoryService] mutateMemoryFactEntry failed: \(error)")
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
                return Self.preview(line, maxChars: MemoryProjectionService.evidenceSnippetBudget)
            }
        }

        return Self.preview(node.content, maxChars: MemoryProjectionService.evidenceSnippetBudget)
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

    private func recentUserEvidence(nodeId: UUID) -> String? {
        guard let messages = try? nodeStore.fetchMessages(nodeId: nodeId) else { return nil }

        for message in messages.reversed() where message.role == .user {
            let cleaned = Self.stripQuoteBlocks(message.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            return Self.preview(cleaned, maxChars: MemoryProjectionService.evidenceSnippetBudget)
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
            return Self.preview(content, maxChars: MemoryProjectionService.evidenceSnippetBudget)
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

    private struct ExtractedDecisionChainPayload: Decodable {
        let rejectedProposal: String?
        let rejection: String?
        let reasons: [String]?
        let replacement: String?
        let evidenceMessageId: String?
        let evidenceQuote: String?
        let confidence: Double?

        enum CodingKeys: String, CodingKey {
            case rejectedProposal = "rejected_proposal"
            case rejection
            case reasons
            case replacement
            case evidenceMessageId = "evidence_message_id"
            case evidenceQuote = "evidence_quote"
            case confidence
        }
    }

    private struct ExtractedSemanticAtomPayload: Decodable {
        let type: String
        let statement: String?
        let corrects: String?
        let evidenceMessageId: String?
        let evidenceQuote: String?
        let confidence: Double?

        enum CodingKeys: String, CodingKey {
            case type
            case statement
            case corrects
            case evidenceMessageId = "evidence_message_id"
            case evidenceQuote = "evidence_quote"
            case confidence
        }
    }

    private struct ExtractedFactEnvelope: Decodable {
        let facts: [ExtractedFactPayload]?
        let decisionChains: [ExtractedDecisionChainPayload]?
        let semanticAtoms: [ExtractedSemanticAtomPayload]?

        enum CodingKeys: String, CodingKey {
            case facts
            case decisionChains = "decision_chains"
            case semanticAtoms = "semantic_atoms"
        }
    }

    private struct ExtractedDecisionChain {
        let rejectedProposal: String
        let rejection: String
        let reasons: [String]
        let replacement: String?
        let evidenceMessageId: UUID?
        let evidenceQuote: String?
        let confidence: Double
    }

    private struct VerifiedDecisionChain {
        let chain: ExtractedDecisionChain
        let sourceMessage: Message
    }

    /// Semantic atoms (preference / belief / correction) live OUTSIDE the
    /// burn-and-replace lifecycle that decision chains use. They are upserted
    /// by normalized_key and survive refresh cycles that don't re-mention
    /// them — otherwise a stable preference Alex stated last week would
    /// disappear the moment this week's chat extracted a different topic.
    private struct ExtractedSemanticAtom {
        let type: MemoryAtomType
        let statement: String
        let correctsTarget: String?
        let evidenceMessageId: UUID?
        let evidenceQuote: String?
        let confidence: Double
    }

    private struct VerifiedSemanticAtom {
        let atom: ExtractedSemanticAtom
        let sourceMessage: Message
    }

    private struct ExtractedMemoryPayload {
        let facts: [(kind: MemoryKind, content: String, confidence: Double)]
        let decisionChains: [ExtractedDecisionChain]
        let semanticAtoms: [ExtractedSemanticAtom]
    }

    private func refreshConversationFacts(
        nodeId: UUID,
        evidenceTurns: [EvidencePromptTurn],
        privacyGuard: MemoryPrivacyGuard,
        now: Date
    ) async {
        guard let llm = llmServiceProvider() else { return }
        let userMessages = evidenceTurns.map(\.message)
        let userTurns = Self.evidencePromptTurns(from: evidenceTurns)
        guard !userTurns.isEmpty else { return }

        let existingBlock = privacyGuard.redact(activeFactBlock(scope: .conversation, scopeRefId: nodeId))
        let prompt = """
        Existing contradiction-oriented facts for this chat:
        \(existingBlock)

        Recent things Alex said (ALEX ONLY — Nous's replies are intentionally omitted to avoid self-confirmation loops):
        \(userTurns)

        Return strict JSON for the currently active memory artefacts for this chat:
        {
          "facts": [
            {"kind":"decision|boundary|constraint","content":"...","confidence":0.0-1.0}
          ],
          "decision_chains": [
            {
              "rejected_proposal":"the option Alex rejected",
              "rejection":"the explicit rejection/decision",
              "reasons":["why it was rejected"],
              "replacement":"the direction chosen instead, if any",
              "evidence_message_id":"the message_id containing the evidence quote",
              "evidence_quote":"short exact quote from Alex's message proving this chain",
              "confidence":0.0-1.0
            }
          ],
          "semantic_atoms": [
            {
              "type":"preference|belief|correction|goal|plan|rule|pattern",
              "statement":"the durable claim in Alex's voice",
              "corrects":"(only when type=correction) short paraphrase of the prior belief/preference/goal/plan/rule Alex is retracting, in the form Alex would have stated it before",
              "evidence_message_id":"the message_id containing the evidence quote",
              "evidence_quote":"short exact quote from Alex's message proving this atom",
              "confidence":0.0-1.0
            }
          ]
        }

        Rules:
        - decision = an explicit choice Alex made
        - boundary = a red line, do-not-cross rule, or operating principle
        - constraint = a real limitation or non-negotiable condition
        - decision_chains are only for explicit reject/deny/not-this moments where Alex gives a reason or replacement direction
        - preference = a durable like / dislike / want / don't-want Alex states
        - belief = a judgement about the world or himself Alex states explicitly
        - correction = an explicit retraction of a prior position ("I no longer ...", "I was wrong that ...")
        - goal = an outcome Alex wants to achieve, with a clear endpoint or aspiration
        - plan = the path or sequence Alex intends to follow toward an outcome
        - rule = an operating principle Alex follows in his work or life — softer than a boundary, sharper than a preference
        - pattern = a recurring behaviour or thought pattern Alex notices about himself
        - For corrections that retract a specific prior belief / preference / goal / plan / rule, include `corrects` matching that prior claim's wording — omit the field when the retraction is generic
        - Every decision_chain and every semantic_atom MUST include evidence_message_id and evidence_quote from one listed Alex message
        - If a line includes [previous_nous_question_context_only], use it only
          to resolve what Alex's short reply refers to. Do not treat Nous context as source evidence; evidence_quote must still come from Alex's message.
        - Preserve exact price, currency, country, city, store, and availability
          wording. Do not invent HKD/USD/CNY, locations, or stock availability.
        - If a short reply remains ambiguous after its context-only question,
          omit the fact instead of guessing.
        - Only keep facts Alex himself said or clearly implied
        - Only keep facts that still seem active for this chat
        - If there are none, return {"facts":[],"decision_chains":[],"semantic_atoms":[]}
        - JSON only. No Markdown, no commentary
        """

        do {
            let stream = try await llm.generate(
                messages: [LLMMessage(role: "user", content: prompt)],
                system: """
                You extract memory for Nous: contradiction-oriented facts (decision/boundary/constraint), \
                decision chains, and semantic atoms (preference/belief/correction).
                Never emit identity or relationship summaries — those belong to other layers.
                Return strict JSON only.
                """
            )

            var raw = ""
            for try await chunk in stream {
                if Task.isCancelled { return }
                raw += chunk
            }

            if Task.isCancelled { return }

            let extraction = try Self.decodeMemoryPayload(raw)
            let verifiedDecisionChains = extraction.decisionChains.compactMap {
                Self.verifiedDecisionChain($0, userMessages: userMessages, privacyGuard: privacyGuard)
            }
            let verifiedSemanticAtoms = extraction.semanticAtoms.compactMap {
                Self.verifiedSemanticAtom($0, userMessages: userMessages, privacyGuard: privacyGuard)
            }
            let facts: [MemoryFactEntry] = extraction.facts.compactMap { payload -> MemoryFactEntry? in
                guard !privacyGuard.referencesProtectedContent(payload.content) else {
                    return nil
                }
                let redactedContent = privacyGuard.redact(payload.content)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !redactedContent.isEmpty,
                      !privacyGuard.referencesProtectedContent(redactedContent)
                else {
                    return nil
                }
                return MemoryFactEntry(
                    scope: .conversation,
                    scopeRefId: nodeId,
                    kind: payload.kind,
                    content: redactedContent,
                    confidence: payload.confidence,
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
                decisionChains: verifiedDecisionChains,
                semanticAtoms: verifiedSemanticAtoms,
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
        decisionChains: [VerifiedDecisionChain] = [],
        semanticAtoms: [VerifiedSemanticAtom] = [],
        now: Date
    ) {
        let embed = embedFunction
        Self.logPersistenceErrors("replaceActiveFacts(\(scope.rawValue))") {
            try nodeStore.inTransaction {
                let writer = MemoryGraphWriter(nodeStore: nodeStore, embed: embed)
                var atoms = try nodeStore.fetchMemoryAtoms()
                var edges = try nodeStore.fetchMemoryEdges()
                var writeResult = MemoryGraphWriteResult()
                let existing = try nodeStore.fetchActiveMemoryFactEntries(
                    scope: scope,
                    scopeRefId: scopeRefId,
                    kinds: Self.contradictionFactKinds
                )
                let newEntries = Self.dedupedFactEntries(entries)
                var pendingByKey: [String: MemoryFactEntry] = [:]
                var pendingOrder: [String] = []
                for entry in newEntries {
                    let key = Self.factKey(kind: entry.kind, content: entry.content)
                    pendingByKey[key] = entry
                    pendingOrder.append(key)
                }
                var consumedKeys = Set<String>()
                var factsToMirror: [MemoryFactEntry] = []
                for var fact in existing {
                    let key = Self.factKey(kind: fact.kind, content: fact.content)
                    if let replacement = pendingByKey[key] {
                        fact.status = .active
                        fact.stability = replacement.stability
                        fact.confidence = max(fact.confidence, replacement.confidence)
                        fact.sourceNodeIds = Self.mergedSourceNodeIds(fact.sourceNodeIds, replacement.sourceNodeIds)
                        fact.updatedAt = now
                        try nodeStore.updateMemoryFactEntry(fact)
                        factsToMirror.append(fact)
                        consumedKeys.insert(key)
                    } else {
                        fact.status = .archived
                        fact.updatedAt = now
                        try nodeStore.updateMemoryFactEntry(fact)
                    }
                }
                try archiveActiveExtractionAtoms(
                    scope: scope,
                    scopeRefId: scopeRefId,
                    now: now
                )
                for key in pendingOrder where !consumedKeys.contains(key) {
                    guard let entry = pendingByKey[key] else { continue }
                    try nodeStore.insertMemoryFactEntry(entry)
                    factsToMirror.append(entry)
                }
                for entry in factsToMirror {
                    if let atom = Self.memoryAtom(from: entry, now: now) {
                        _ = try writer.upsertAtom(atom, atoms: &atoms, result: &writeResult)
                    }
                }
                for chain in decisionChains {
                    try insertDecisionChainAtoms(
                        chain,
                        scope: scope,
                        scopeRefId: scopeRefId,
                        now: now,
                        writer: writer,
                        atoms: &atoms,
                        edges: &edges,
                        result: &writeResult
                    )
                }
                for verified in semanticAtoms {
                    let candidate = Self.semanticAtom(
                        verified,
                        scope: scope,
                        scopeRefId: scopeRefId,
                        now: now
                    )
                    let upserted = try writer.upsertAtom(
                        candidate,
                        atoms: &atoms,
                        result: &writeResult
                    )
                    if verified.atom.type == .correction,
                       let correctsText = verified.atom.correctsTarget {
                        // Pattern atoms intentionally excluded — patterns
                        // describe self-observation, not commitment, so they
                        // fade by absence rather than being retracted.
                        try writer.supersedeMatchingClaims(
                            matching: correctsText,
                            targetTypes: [.belief, .preference, .goal, .plan, .rule],
                            superseder: upserted,
                            confidence: verified.atom.confidence,
                            now: now,
                            atoms: &atoms,
                            edges: &edges,
                            result: &writeResult
                        )
                    }
                }
            }
        }
    }

    private static func semanticAtom(
        _ verified: VerifiedSemanticAtom,
        scope: MemoryScope,
        scopeRefId: UUID?,
        now: Date
    ) -> MemoryAtom {
        let sourceNodeId = scope == .conversation ? scopeRefId : nil
        return MemoryAtom(
            type: verified.atom.type,
            statement: verified.atom.statement,
            normalizedKey: MemoryGraphWriter.normalizedKey(
                type: verified.atom.type,
                statement: verified.atom.statement
            ),
            scope: scope,
            scopeRefId: scopeRefId,
            status: .active,
            confidence: verified.atom.confidence,
            eventTime: verified.sourceMessage.timestamp,
            createdAt: now,
            updatedAt: now,
            lastSeenAt: now,
            sourceNodeId: sourceNodeId,
            sourceMessageId: verified.sourceMessage.id
        )
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
    static func stripQuoteBlocks(_ content: String) -> String {
        MemoryProjectionService.stripQuoteBlocks(content)
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

    private static func cleanedEvidenceTurns(from messages: [Message]) -> [EvidencePromptTurn] {
        let assistantTurns: [String] = messages
            .filter { $0.role == .assistant }
            .map { Self.stripQuoteBlocks($0.content) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return messages.enumerated().compactMap { offset, msg -> EvidencePromptTurn? in
            guard msg.role == .user else { return nil }
            let stripped = Self.stripQuoteBlocks(msg.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return nil }
            let optOutPhrases = SafetyGuardrails.matchedHardMemoryOptOutPhrases(in: stripped)
            let isHardOptOut = !optOutPhrases.isEmpty
            for assistantTurn in assistantTurns {
                if Self.tokenJaccard(stripped, assistantTurn) >= 0.6 {
                    return nil
                }
            }
            let protectedFragments = isHardOptOut
                ? Self.protectedFragments(fromHardOptOutText: stripped, matchedOptOutPhrases: optOutPhrases)
                : []
            let cleaned = Message(
                id: msg.id,
                nodeId: msg.nodeId,
                role: msg.role,
                content: isHardOptOut ? MemoryPrivacyGuard.redactedEvidenceLine : stripped,
                timestamp: msg.timestamp,
                thinkingContent: nil
            )
            return EvidencePromptTurn(
                message: cleaned,
                previousAssistantQuestion: previousAssistantQuestion(
                    before: offset,
                    in: messages,
                    userContent: stripped
                ),
                protectedFragments: protectedFragments,
                isHardOptOut: isHardOptOut
            )
        }
    }

    private static func memoryPrivacyGuard(from turns: [EvidencePromptTurn]) -> MemoryPrivacyGuard {
        var fragments: [String] = []
        var seenFragments = Set<String>()
        var optOutMessageIds = Set<UUID>()

        for turn in turns where turn.isHardOptOut {
            optOutMessageIds.insert(turn.message.id)
            for fragment in turn.protectedFragments {
                let normalized = MemoryGraphAtomMapper.normalizedLine(fragment)
                guard !normalized.isEmpty, seenFragments.insert(normalized).inserted else {
                    continue
                }
                fragments.append(fragment)
            }
        }

        return MemoryPrivacyGuard(
            protectedFragments: fragments,
            optOutMessageIds: optOutMessageIds
        )
    }

    private static func protectedFragments(
        fromHardOptOutText text: String,
        matchedOptOutPhrases: [String]
    ) -> [String] {
        var fragments: [String] = []
        var seen = Set<String>()

        func admit(_ raw: String) {
            let fragment = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’「」『』（）()[]{}，,。.!！?？；;：:"))
            let normalized = MemoryGraphAtomMapper.normalizedLine(fragment)
            guard fragment.count >= 2,
                  fragment.count <= 80,
                  !matchedOptOutPhrases.contains(where: { normalized.contains(MemoryGraphAtomMapper.normalizedLine($0)) }),
                  !Self.isGenericOptOutFragment(normalized),
                  seen.insert(normalized).inserted
            else {
                return
            }
            fragments.append(fragment)
        }

        for quotePattern in [
            #""([^"]{2,80})""#,
            #"'([^']{2,80})'"#,
            #"`([^`]{2,80})`"#,
            #"“([^”]{2,80})”"#,
            #"「([^」]{2,80})」"#,
            #"『([^』]{2,80})』"#
        ] {
            for match in Self.regexCaptures(pattern: quotePattern, in: text) {
                admit(match)
            }
        }

        for namedPattern in [
            #"起名叫\s*([^。.!！？，,；;\n]{2,80})"#,
            #"叫\s*([^。.!！？，,；;\n]{2,80})"#,
            #"named\s+(?:it\s+)?([A-Za-z0-9][A-Za-z0-9 _-]{2,80})"#,
            #"called\s+(?:it\s+)?([A-Za-z0-9][A-Za-z0-9 _-]{2,80})"#
        ] {
            for match in Self.regexCaptures(pattern: namedPattern, in: text) {
                admit(match)
            }
        }

        return fragments
    }

    private static func regexCaptures(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text)
            else {
                return nil
            }
            return String(text[captureRange])
        }
    }

    private static func isGenericOptOutFragment(_ normalized: String) -> Bool {
        let genericFragments = [
            "this",
            "memory",
            "durable memory",
            "long term memory",
            "user profile",
            "conversation",
            "testing detail",
            "测试细节",
            "測試細節",
            "这件事",
            "這件事",
            "呢件事",
            "不要记住",
            "不要記住",
            "唔好记住",
            "唔好記住"
        ]
        return genericFragments.contains(normalized)
    }

    private static func evidencePromptTurns(from turns: [EvidencePromptTurn]) -> String {
        turns
            .map { turn in
                let timestamp = evidenceTimestampFormatter.string(from: turn.message.timestamp)
                var lines: [String] = []
                if let previous = turn.previousAssistantQuestion {
                    lines.append("[previous_nous_question_context_only] \(previous)")
                }
                lines.append("[message_id=\(turn.message.id.uuidString) timestamp=\(timestamp)] \(turn.message.content)")
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n---\n")
    }

    private static func previousAssistantQuestion(
        before index: Int,
        in messages: [Message],
        userContent: String
    ) -> String? {
        guard needsPreviousQuestionContext(userContent) else { return nil }
        guard index > 0 else { return nil }

        for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
            let candidate = messages[candidateIndex]
            if candidate.role == .user { continue }
            guard candidate.role == .assistant else { continue }
            return assistantQuestionExcerpt(candidate.content)
        }
        return nil
    }

    private static func needsPreviousQuestionContext(_ content: String) -> Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).count <= 40
    }

    private static func assistantQuestionExcerpt(_ content: String) -> String? {
        let cleaned = stripQuoteBlocks(content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let lines = cleaned
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let questionLine = lines.last(where: { isQuestionLike($0) }) else {
            return nil
        }
        if cleaned.count <= 180 {
            return preview(cleaned, maxChars: 180)
        }
        if let questionIndex = lines.lastIndex(where: { isQuestionLike($0) }) {
            let start = max(lines.startIndex, lines.index(questionIndex, offsetBy: -1, limitedBy: lines.startIndex) ?? lines.startIndex)
            return preview(lines[start...questionIndex].joined(separator: " "), maxChars: 180)
        }
        return preview(questionLine, maxChars: 180)
    }

    private static func isQuestionLike(_ content: String) -> Bool {
        content.contains("?") || content.contains("？")
    }

    private static func verifiedDecisionChain(
        _ chain: ExtractedDecisionChain,
        userMessages: [Message],
        privacyGuard: MemoryPrivacyGuard
    ) -> VerifiedDecisionChain? {
        guard !privacyGuard.referencesProtectedContent(chain.rejectedProposal),
              !privacyGuard.referencesProtectedContent(chain.rejection),
              !chain.reasons.contains(where: privacyGuard.referencesProtectedContent),
              !privacyGuard.referencesProtectedContent(chain.replacement ?? ""),
              !privacyGuard.referencesProtectedContent(chain.evidenceQuote ?? "")
        else {
            return nil
        }
        guard let match = MemoryGraphEvidenceMatcher.match(
            evidenceMessageId: chain.evidenceMessageId,
            evidenceQuote: chain.evidenceQuote,
            messages: userMessages
        ) else {
            return nil
        }
        guard !privacyGuard.blocks(sourceMessageId: match.message.id) else {
            return nil
        }

        return VerifiedDecisionChain(chain: chain, sourceMessage: match.message)
    }

    private static func verifiedSemanticAtom(
        _ atom: ExtractedSemanticAtom,
        userMessages: [Message],
        privacyGuard: MemoryPrivacyGuard
    ) -> VerifiedSemanticAtom? {
        guard !privacyGuard.referencesProtectedContent(atom.statement),
              !privacyGuard.referencesProtectedContent(atom.correctsTarget ?? ""),
              !privacyGuard.referencesProtectedContent(atom.evidenceQuote ?? "")
        else {
            return nil
        }
        guard let match = MemoryGraphEvidenceMatcher.match(
            evidenceMessageId: atom.evidenceMessageId,
            evidenceQuote: atom.evidenceQuote,
            messages: userMessages
        ) else {
            return nil
        }
        guard !privacyGuard.blocks(sourceMessageId: match.message.id) else {
            return nil
        }
        return VerifiedSemanticAtom(atom: atom, sourceMessage: match.message)
    }

    private static func normalizedLine(_ content: String) -> String {
        content
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func decodeFactPayloads(_ raw: String) throws -> [(kind: MemoryKind, content: String, confidence: Double)] {
        try decodeMemoryPayload(raw).facts
    }

    private static func decodeMemoryPayload(_ raw: String) throws -> ExtractedMemoryPayload {
        let decoder = JSONDecoder()
        let cleaned = stripJSONCodeFence(raw)
        guard let data = cleaned.data(using: .utf8) else {
            throw LLMError.invalidResponse
        }

        let factPayloads: [ExtractedFactPayload]
        let chainPayloads: [ExtractedDecisionChainPayload]
        let semanticAtomPayloads: [ExtractedSemanticAtomPayload]
        if let direct = try? decoder.decode([ExtractedFactPayload].self, from: data) {
            factPayloads = direct
            chainPayloads = []
            semanticAtomPayloads = []
        } else if let wrapped = try? decoder.decode(ExtractedFactEnvelope.self, from: data) {
            factPayloads = wrapped.facts ?? []
            chainPayloads = wrapped.decisionChains ?? []
            semanticAtomPayloads = wrapped.semanticAtoms ?? []
        } else {
            throw LLMError.invalidResponse
        }

        let facts: [(kind: MemoryKind, content: String, confidence: Double)] = factPayloads.compactMap { payload in
            guard let kind = contradictionFactKind(from: payload.kind) else { return nil }
            let content = payload.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return (
                kind: kind,
                content: content,
                confidence: clampConfidence(payload.confidence ?? 0.8)
            )
        }

        let decisionChains = chainPayloads.compactMap { payload -> ExtractedDecisionChain? in
            guard let rejectedProposal = payload.rejectedProposal?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rejectedProposal.isEmpty,
                  let rejection = payload.rejection?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rejection.isEmpty
            else {
                return nil
            }

            let reasons = (payload.reasons ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let replacement = payload.replacement?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let evidenceQuote = payload.evidenceQuote?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let evidenceMessageId = payload.evidenceMessageId
                .flatMap(UUID.init(uuidString:))

            return ExtractedDecisionChain(
                rejectedProposal: rejectedProposal,
                rejection: rejection,
                reasons: reasons,
                replacement: replacement?.isEmpty == true ? nil : replacement,
                evidenceMessageId: evidenceMessageId,
                evidenceQuote: evidenceQuote?.isEmpty == true ? nil : evidenceQuote,
                confidence: clampConfidence(payload.confidence ?? 0.8)
            )
        }

        let semanticAtoms = semanticAtomPayloads.compactMap { payload -> ExtractedSemanticAtom? in
            guard let type = semanticAtomType(from: payload.type) else { return nil }
            let statement = payload.statement?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !statement.isEmpty else { return nil }
            let evidenceQuote = payload.evidenceQuote?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let evidenceMessageId = payload.evidenceMessageId
                .flatMap(UUID.init(uuidString:))
            let correctsTarget = payload.corrects?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ExtractedSemanticAtom(
                type: type,
                statement: statement,
                correctsTarget: correctsTarget?.isEmpty == true ? nil : correctsTarget,
                evidenceMessageId: evidenceMessageId,
                evidenceQuote: evidenceQuote?.isEmpty == true ? nil : evidenceQuote,
                confidence: clampConfidence(payload.confidence ?? 0.8)
            )
        }

        return ExtractedMemoryPayload(
            facts: facts,
            decisionChains: decisionChains,
            semanticAtoms: semanticAtoms
        )
    }

    private static let semanticAtomTypes: Set<MemoryAtomType> = [
        .preference, .belief, .correction,
        .goal, .plan, .rule, .pattern
    ]

    private static func semanticAtomType(from raw: String) -> MemoryAtomType? {
        let normalized = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let type = MemoryAtomType(rawValue: normalized) else { return nil }
        guard semanticAtomTypes.contains(type) else { return nil }
        return type
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

    private static func mergedSourceNodeIds(_ lhs: [UUID], _ rhs: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var merged: [UUID] = []
        for id in lhs + rhs where seen.insert(id).inserted {
            merged.append(id)
        }
        return merged
    }

    private static func factKey(kind: MemoryKind, content: String) -> String {
        MemoryGraphAtomMapper.factNormalizedKey(kind: kind, content: content)
    }

    private static func memoryAtom(from entry: MemoryFactEntry, now: Date) -> MemoryAtom? {
        MemoryGraphAtomMapper.atom(fromFact: entry, now: now)
    }

    private func insertDecisionChainAtoms(
        _ verified: VerifiedDecisionChain,
        scope: MemoryScope,
        scopeRefId: UUID?,
        now: Date,
        writer: MemoryGraphWriter,
        atoms: inout [MemoryAtom],
        edges: inout [MemoryEdge],
        result: inout MemoryGraphWriteResult
    ) throws {
        let sourceNodeId = scope == .conversation ? scopeRefId : nil
        try writer.writeDecisionChain(
            MemoryGraphDecisionChainInput(
                rejectedProposal: verified.chain.rejectedProposal,
                rejection: verified.chain.rejection,
                reasons: verified.chain.reasons,
                replacement: verified.chain.replacement,
                confidence: verified.chain.confidence,
                scope: scope,
                scopeRefId: scopeRefId,
                eventTime: verified.sourceMessage.timestamp,
                sourceNodeId: sourceNodeId,
                sourceMessageId: persistedSourceMessageId(verified.sourceMessage),
                now: now
            ),
            atoms: &atoms,
            edges: &edges,
            result: &result
        )
    }

    private func persistedSourceMessageId(_ message: Message) -> UUID? {
        guard let messages = try? nodeStore.fetchMessages(nodeId: message.nodeId),
              messages.contains(where: { $0.id == message.id })
        else {
            return nil
        }
        return message.id
    }

    private static let extractionGeneratedAtomTypes: Set<MemoryAtomType> = [
        .decision,
        .boundary,
        .constraint,
        .proposal,
        .rejection,
        .reason,
        .currentPosition
    ]

    private func archiveActiveExtractionAtoms(scope: MemoryScope, scopeRefId: UUID?, now: Date) throws {
        let atoms = try nodeStore.fetchMemoryAtoms(
            types: Self.extractionGeneratedAtomTypes,
            statuses: [.active],
            scope: scope,
            scopeRefId: scopeRefId,
            eventTimeStart: nil,
            eventTimeEnd: nil,
            limit: nil
        )

        for var atom in atoms {
            atom.status = .archived
            atom.updatedAt = now
            try nodeStore.updateMemoryAtom(atom)
        }
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
            let stableGlobalMemoryKeys = stableGlobalMemoryClaimKeys()
            let reflections = (try? nodeStore.fetchActiveReflectionClaims(projectId: projectId)) ?? []
            var admittedReflections = 0
            for claim in reflections {
                guard admittedReflections < reflectionSeed else { break }
                guard !Self.claimOverlapsStableMemory(
                    claim.claim,
                    stableGlobalMemoryKeys: stableGlobalMemoryKeys
                ) else {
                    continue
                }
                let countBefore = out.count
                admit(CitableEntry(
                    id: claim.id.uuidString,
                    text: claim.claim,
                    scope: .selfReflection,
                    kind: nil,
                    promptAnnotation: "weekly-reflection"
                ))
                if out.count > countBefore {
                    admittedReflections += 1
                }
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

    private func stableGlobalMemoryClaimKeys() -> Set<String> {
        guard let entry = try? nodeStore.fetchActiveMemoryEntry(scope: .global, scopeRefId: nil) else {
            return []
        }
        return Self.normalizedMemoryClaimKeys(from: entry.content)
    }

    private static func claimOverlapsStableMemory(
        _ claim: String,
        stableGlobalMemoryKeys: Set<String>
    ) -> Bool {
        let claimKey = normalizedMemoryClaim(claim)
        guard !claimKey.isEmpty else { return false }

        return stableGlobalMemoryKeys.contains { stableKey in
            guard stableKey.split(separator: " ").count >= 3 else { return false }
            return claimKey == stableKey ||
                claimKey.contains(stableKey) ||
                stableKey.contains(claimKey)
        }
    }

    private static func normalizedMemoryClaimKeys(from content: String) -> Set<String> {
        var keys = Set<String>()
        for line in content.components(separatedBy: .newlines) {
            let key = normalizedMemoryClaim(line)
            if !key.isEmpty { keys.insert(key) }
        }

        let whole = normalizedMemoryClaim(content)
        if !whole.isEmpty { keys.insert(whole) }
        return keys
    }

    private static func normalizedMemoryClaim(_ content: String) -> String {
        strippedMemoryLine(content)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func strippedMemoryLine(_ content: String) -> String {
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        while trimmed.hasPrefix("#") {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for marker in ["- ", "* "] {
            if trimmed.hasPrefix(marker) {
                return String(trimmed.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let dot = trimmed.firstIndex(of: ".") {
            let prefix = trimmed[..<dot]
            if !prefix.isEmpty && prefix.allSatisfy(\.isNumber) {
                return String(trimmed[trimmed.index(after: dot)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return trimmed
    }
}
