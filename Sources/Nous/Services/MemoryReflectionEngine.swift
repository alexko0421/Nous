import Foundation

struct MemoryReflectionProposalResult: Equatable {
    let inboxItem: MemoryInboxItem
    let sourceAtomIds: [UUID]
}

typealias MemoryReflectionInsightSummarizer = ([MemoryAtom]) async throws -> String?

struct MemoryReflectionLLMSummarizer {
    let llmService: any LLMService

    func summarize(_ sources: [MemoryAtom]) async throws -> String? {
        guard !sources.isEmpty else { return nil }
        let stream = try await llmService.generate(
            messages: [LLMMessage(role: "user", content: Self.prompt(for: sources))],
            system: Self.systemPrompt
        )
        var output = ""
        for try await chunk in stream {
            if Task.isCancelled { return nil }
            output += chunk
        }
        return Self.cleaned(output)
    }

    private static let systemPrompt = """
    You write one pending memory proposal for Alex's personal AI memory inbox.
    Use only the approved source memories provided.
    Return one concise reflective insight in Alex-specific language.
    Do not invent facts, do not mention hidden reasoning, and do not approve the memory yourself.
    This is a pending memory proposal that Alex may save, edit, or reject.
    """

    private static func prompt(for sources: [MemoryAtom]) -> String {
        let sourceLines = sources.enumerated().map { index, atom in
            let scope = atom.scopeRefId.map { "\(atom.scope.rawValue):\($0.uuidString)" } ?? atom.scope.rawValue
            return """
            \(index + 1). type=\(atom.type.rawValue) scope=\(scope) confidence=\(String(format: "%.2f", atom.confidence))
            \(atom.statement)
            """
        }.joined(separator: "\n\n")

        return """
        Approved source memories:

        \(sourceLines)

        Write exactly one reflective insight sentence or short paragraph.
        It must be suitable as a pending memory proposal, not as an active fact.
        """
    }

    private static func cleaned(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text.removeFirst()
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }
}

final class MemoryReflectionEngine {
    private let nodeStore: NodeStore
    private let lifecycle: MemoryLifecycleEngine
    private let synthesizeInsight: ([MemoryAtom]) -> String?

    init(
        nodeStore: NodeStore,
        embed: @escaping (String) -> [Float]? = { _ in nil },
        synthesizeInsight: (([MemoryAtom]) -> String?)? = nil
    ) {
        self.nodeStore = nodeStore
        self.lifecycle = MemoryLifecycleEngine(nodeStore: nodeStore, embed: embed)
        self.synthesizeInsight = synthesizeInsight ?? Self.defaultInsight
    }

    @discardableResult
    func proposeReflection(
        insight rawInsight: String,
        sourceAtomIds rawSourceAtomIds: [UUID],
        confidence: Double,
        now: Date = Date()
    ) throws -> MemoryReflectionProposalResult? {
        let insight = rawInsight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !insight.isEmpty else { return nil }

        let sourceAtomIds = orderedUnique(rawSourceAtomIds)
        let sources = try sourceAtomIds.compactMap { try nodeStore.fetchMemoryAtom(id: $0) }
            .filter { $0.status == .active && Self.isCurrentlyValid($0, now: now) }
        guard sources.count >= 2 else { return nil }

        let proposal = MemoryAtom(
            type: .insight,
            statement: insight,
            normalizedKey: MemoryGraphWriter.normalizedKey(type: .insight, statement: insight),
            scope: .selfReflection,
            status: .pending,
            confidence: Self.clamp01(confidence),
            eventTime: now,
            createdAt: now,
            updatedAt: now
        )

        var proposalResult: MemoryReflectionProposalResult?
        try nodeStore.inTransaction {
            if let existing = try pendingReflectionProposalResult(fallbackSourceAtomIds: sources.map(\.id)) {
                proposalResult = existing
                return
            }

            let staged = try lifecycle.stageAtomProposal(proposal, now: now)
            guard staged.status != .archived else { return }

            try linkReflection(staged, to: sources, now: now)

            guard staged.status == .pending else { return }
            proposalResult = MemoryReflectionProposalResult(
                inboxItem: MemoryInboxItem(
                    atom: staged,
                    temporalScope: .reflective,
                    reason: "reflection from approved memories"
                ),
                sourceAtomIds: sources.map(\.id)
            )
        }
        return proposalResult
    }

    @discardableResult
    func proposeFromActiveMemory(
        projectId: UUID?,
        conversationId: UUID?,
        sourceLimit: Int = 8,
        minimumSources: Int = 3,
        now: Date = Date()
    ) throws -> MemoryReflectionProposalResult? {
        guard sourceLimit > 0, minimumSources > 1 else { return nil }

        let candidates = try automaticReflectionSources(
            projectId: projectId,
            conversationId: conversationId,
            sourceLimit: sourceLimit,
            minimumSources: minimumSources,
            now: now
        )
        guard candidates.count >= minimumSources,
              let insight = synthesizeInsight(candidates)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !insight.isEmpty
        else { return nil }

        return try proposeReflection(
            insight: insight,
            sourceAtomIds: candidates.map(\.id),
            confidence: Self.averageConfidence(candidates),
            now: now
        )
    }

    @discardableResult
    func proposeSummarizedFromActiveMemory(
        projectId: UUID?,
        conversationId: UUID?,
        sourceLimit: Int = 8,
        minimumSources: Int = 3,
        now: Date = Date(),
        summarizeInsight: MemoryReflectionInsightSummarizer?
    ) async throws -> MemoryReflectionProposalResult? {
        guard sourceLimit > 0, minimumSources > 1 else { return nil }

        let candidates = try automaticReflectionSources(
            projectId: projectId,
            conversationId: conversationId,
            sourceLimit: sourceLimit,
            minimumSources: minimumSources,
            now: now
        )
        guard candidates.count >= minimumSources else { return nil }

        let summarized = try? await summarizeInsight?(candidates)
        let insight = Self.nonEmpty(summarized) ?? Self.nonEmpty(synthesizeInsight(candidates))
        guard let insight else { return nil }

        return try proposeReflection(
            insight: insight,
            sourceAtomIds: candidates.map(\.id),
            confidence: Self.averageConfidence(candidates),
            now: now
        )
    }

    private func automaticReflectionSources(
        projectId: UUID?,
        conversationId: UUID?,
        sourceLimit: Int,
        minimumSources: Int,
        now: Date
    ) throws -> [MemoryAtom] {
        guard sourceLimit > 0, minimumSources > 1 else { return [] }

        return try nodeStore.fetchMemoryAtoms(
            types: Self.automaticReflectionSourceTypes,
            statuses: [.active],
            scope: nil,
            scopeRefId: nil,
            eventTimeStart: nil,
            eventTimeEnd: nil,
            limit: nil
        )
        .filter { atom in
            Self.isCurrentlyValid(atom, now: now)
                && isInAutomaticReflectionScope(atom, projectId: projectId, conversationId: conversationId)
        }
        .sorted {
            let left = Self.sourceRank($0, now: now)
            let right = Self.sourceRank($1, now: now)
            if left == right {
                return ($0.eventTime ?? $0.updatedAt) > ($1.eventTime ?? $1.updatedAt)
            }
            return left > right
        }
        .prefix(sourceLimit)
        .map { $0 }
    }

    private func pendingReflectionProposalResult(
        fallbackSourceAtomIds: [UUID]
    ) throws -> MemoryReflectionProposalResult? {
        guard let atom = try nodeStore.fetchMemoryAtoms(
            types: [.insight],
            statuses: [.pending],
            scope: .selfReflection,
            scopeRefId: nil,
            eventTimeStart: nil,
            eventTimeEnd: nil,
            limit: 1
        ).first else { return nil }

        let linkedSourceAtomIds = try nodeStore.fetchMemoryEdges(fromAtomId: atom.id)
            .filter { $0.type == .derivedFrom }
            .map(\.toAtomId)

        return MemoryReflectionProposalResult(
            inboxItem: MemoryInboxItem(
                atom: atom,
                temporalScope: .reflective,
                reason: "reflection from approved memories"
            ),
            sourceAtomIds: linkedSourceAtomIds.isEmpty ? fallbackSourceAtomIds : linkedSourceAtomIds
        )
    }

    private func linkReflection(
        _ reflection: MemoryAtom,
        to sources: [MemoryAtom],
        now: Date
    ) throws {
        let writer = MemoryGraphWriter(nodeStore: nodeStore)
        var edges = try nodeStore.fetchMemoryEdges()
        var result = MemoryGraphWriteResult()

        for source in sources {
            try writer.link(
                from: reflection.id,
                to: source.id,
                type: .derivedFrom,
                weight: Self.clamp01(source.confidence),
                sourceMessageId: source.sourceMessageId,
                createdAt: now,
                edges: &edges,
                result: &result
            )
        }
    }

    private func isInAutomaticReflectionScope(
        _ atom: MemoryAtom,
        projectId: UUID?,
        conversationId: UUID?
    ) -> Bool {
        switch atom.scope {
        case .global:
            return true
        case .project:
            guard let projectId else { return false }
            return atom.scopeRefId == projectId
        case .conversation:
            guard let scopeRefId = atom.scopeRefId else { return false }
            if let conversationId, scopeRefId == conversationId { return true }
            guard let projectId,
                  let sourceNode = try? nodeStore.fetchNode(id: scopeRefId)
            else { return false }
            return sourceNode.projectId == projectId
        case .selfReflection:
            return false
        }
    }

    private func orderedUnique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        var result: [UUID] = []
        for id in ids where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    private static func isCurrentlyValid(_ atom: MemoryAtom, now: Date) -> Bool {
        if let validFrom = atom.validFrom, validFrom > now { return false }
        if let validUntil = atom.validUntil, validUntil <= now { return false }
        return true
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static let automaticReflectionSourceTypes: Set<MemoryAtomType> = [
        .identity,
        .preference,
        .rule,
        .boundary,
        .constraint,
        .goal,
        .plan,
        .decision,
        .belief,
        .entity,
        .task,
        .currentPosition
    ]

    static func isAutomaticReflectionSource(_ atom: MemoryAtom) -> Bool {
        automaticReflectionSourceTypes.contains(atom.type) && atom.scope != .selfReflection
    }

    private static func sourceRank(_ atom: MemoryAtom, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(atom.eventTime ?? atom.updatedAt))
        let recency = exp(-age / (14 * 24 * 60 * 60))
        return clamp01(atom.confidence) * 0.65 + recency * 0.35
    }

    private static func averageConfidence(_ atoms: [MemoryAtom]) -> Double {
        guard !atoms.isEmpty else { return 0 }
        let average = atoms.reduce(0) { $0 + clamp01($1.confidence) } / Double(atoms.count)
        return min(0.95, max(0.5, average))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func defaultInsight(from sources: [MemoryAtom]) -> String? {
        let lines = sources
            .prefix(3)
            .map { preview($0.statement, maxCharacters: 80) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }
        return "Emerging memory pattern: \(lines.joined(separator: " / "))"
    }

    private static func preview(_ text: String, maxCharacters: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
