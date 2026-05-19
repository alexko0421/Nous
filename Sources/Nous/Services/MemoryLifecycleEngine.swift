import Foundation

enum MemoryTemporalScope: String, Codable, CaseIterable, Equatable {
    case working
    case episodic
    case semantic
    case procedural
    case reflective
}

struct MemoryInboxItem: Identifiable, Equatable {
    var id: UUID { atom.id }
    let atom: MemoryAtom
    let temporalScope: MemoryTemporalScope
    let reason: String
}

enum MemoryLifecycleStageResult: Equatable {
    case staged(MemoryInboxItem)
    case suppressed(reason: MemorySuppressionReason, curatorReason: String)
}

struct MemoryHybridRecallScore: Equatable {
    let semantic: Double
    let graph: Double
    let recency: Double
    let importance: Double
    let interaction: Double

    var final: Double {
        semantic * 0.40
            + graph * 0.20
            + recency * 0.15
            + importance * 0.15
            + interaction * 0.10
    }
}

struct MemoryHybridRecallResult: Identifiable, Equatable {
    var id: UUID { atom.id }
    let atom: MemoryAtom
    let score: MemoryHybridRecallScore
    let reason: String
}

final class MemoryLifecycleEngine {
    private let nodeStore: NodeStore
    private let curator: MemoryCurator
    private let embed: (String) -> [Float]?
    private let automaticReflectionMinimumSources: Int
    private let automaticReflectionSourceLimit: Int
    private let reflectionSynthesizeInsight: (([MemoryAtom]) -> String?)?
    private static let rejectedProposalReason = "matching memory proposal was rejected"

    init(
        nodeStore: NodeStore,
        curator: MemoryCurator = MemoryCurator(),
        embed: @escaping (String) -> [Float]? = { _ in nil },
        automaticReflectionMinimumSources: Int = 3,
        automaticReflectionSourceLimit: Int = 8,
        reflectionSynthesizeInsight: (([MemoryAtom]) -> String?)? = nil
    ) {
        self.nodeStore = nodeStore
        self.curator = curator
        self.embed = embed
        self.automaticReflectionMinimumSources = automaticReflectionMinimumSources
        self.automaticReflectionSourceLimit = automaticReflectionSourceLimit
        self.reflectionSynthesizeInsight = reflectionSynthesizeInsight
    }

    @discardableResult
    func stageFromUserText(
        _ text: String,
        projectId: UUID?,
        conversationId: UUID,
        sourceNodeId: UUID?,
        sourceMessageId: UUID?,
        boundaryLines: [String] = [],
        now: Date = Date()
    ) throws -> MemoryLifecycleStageResult {
        let assessment = curator.assess(
            latestUserText: text,
            boundaryLines: boundaryLines
        )
        guard assessment.persistenceDecision.shouldPersist else {
            return .suppressed(
                reason: assessment.persistenceDecision.suppressionReason ?? .unspecified,
                curatorReason: assessment.reason
            )
        }

        let statement = Self.cleanStatement(text)
        guard !statement.isEmpty else {
            return .suppressed(reason: .unspecified, curatorReason: "empty memory proposal")
        }

        let atomType = Self.atomType(for: assessment.kind, statement: statement)
        let temporalScope = Self.temporalScope(for: atomType)
        let scope = Self.storageScope(for: atomType, projectId: projectId)
        let scopeRefId: UUID? = {
            switch scope {
            case .global, .selfReflection:
                return nil
            case .project:
                return projectId
            case .conversation:
                return conversationId
            }
        }()

        let proposal = MemoryAtom(
            type: atomType,
            statement: statement,
            normalizedKey: MemoryGraphWriter.normalizedKey(type: atomType, statement: statement),
            scope: scope,
            scopeRefId: scopeRefId,
            status: .pending,
            confidence: Self.confidence(for: assessment.lifecycle),
            eventTime: now,
            createdAt: now,
            updatedAt: now,
            lastSeenAt: nil,
            sourceNodeId: sourceNodeId,
            sourceMessageId: sourceMessageId,
            embedding: embed(statement)
        )

        let atom = try stageAtomProposal(proposal, now: now)
        guard atom.status != .archived else {
            return .suppressed(reason: .unspecified, curatorReason: Self.rejectedProposalReason)
        }
        return .staged(MemoryInboxItem(
            atom: atom,
            temporalScope: temporalScope,
            reason: assessment.reason
        ))
    }

    @discardableResult
    func stageAtomProposal(
        _ candidate: MemoryAtom,
        now: Date = Date()
    ) throws -> MemoryAtom {
        let statement = candidate.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { return candidate }

        var proposal = candidate
        proposal.statement = statement
        proposal.status = .pending
        proposal.updatedAt = now
        proposal.normalizedKey = proposal.normalizedKey
            ?? MemoryGraphWriter.normalizedKey(type: proposal.type, statement: statement)
        if proposal.embedding == nil {
            proposal.embedding = embed(statement)
        }

        let existing = try matchingLifecycleAtom(for: proposal)
        guard let existing else {
            try nodeStore.insertMemoryAtom(proposal)
            return proposal
        }
        guard existing.status != .archived else {
            return existing
        }

        var merged = existing
        merged.statement = proposal.statement
        merged.normalizedKey = proposal.normalizedKey ?? existing.normalizedKey
        merged.status = existing.status == .active ? .active : .pending
        merged.confidence = max(existing.confidence, proposal.confidence)
        merged.eventTime = existing.eventTime ?? proposal.eventTime
        merged.validFrom = existing.validFrom ?? proposal.validFrom
        merged.validUntil = proposal.validUntil ?? existing.validUntil
        merged.updatedAt = now
        merged.lastSeenAt = existing.status == .active
            ? Self.maxDate(existing.lastSeenAt, now)
            : existing.lastSeenAt
        merged.sourceNodeId = existing.sourceNodeId ?? proposal.sourceNodeId
        merged.sourceMessageId = existing.sourceMessageId ?? proposal.sourceMessageId
        merged.evidenceQuote = existing.evidenceQuote ?? proposal.evidenceQuote
        merged.captureReason = existing.captureReason ?? proposal.captureReason
        merged.correctsTarget = proposal.correctsTarget ?? existing.correctsTarget
        merged.embedding = existing.embedding ?? proposal.embedding
        try nodeStore.updateMemoryAtom(merged)
        return merged
    }

    func inbox(limit: Int = 25) throws -> [MemoryInboxItem] {
        try nodeStore.fetchMemoryAtoms(
            types: [],
            statuses: [.pending],
            scope: nil,
            scopeRefId: nil,
            eventTimeStart: nil,
            eventTimeEnd: nil,
            limit: limit
        )
        .map { atom in
            MemoryInboxItem(
                atom: atom,
                temporalScope: Self.temporalScope(for: atom.type),
                reason: "awaiting approval"
            )
        }
    }

    @discardableResult
    func approve(_ atomId: UUID, now: Date = Date()) throws -> MemoryAtom? {
        var approved: MemoryAtom?
        var didActivatePendingAtom = false
        try nodeStore.inTransaction {
            guard var atom = try nodeStore.fetchMemoryAtom(id: atomId) else { return }
            guard atom.status == .pending else {
                if atom.authority == .tentative {
                    atom.authority = .durable
                    atom.updatedAt = now
                    try nodeStore.updateMemoryAtom(atom)
                }
                approved = atom
                return
            }
            atom.status = .active
            atom.authority = .durable
            atom.updatedAt = now
            atom.lastSeenAt = now
            try nodeStore.updateMemoryAtom(atom)
            try applyApprovalSideEffects(for: atom, now: now)
            try syncMirroredFactLifecycle(for: atom, status: .active, now: now)
            approved = atom
            didActivatePendingAtom = true
        }
        if didActivatePendingAtom, let approved {
            try triggerAutomaticReflectionIfNeeded(afterApproving: approved, now: now)
        }
        return approved
    }

    @discardableResult
    func stageAutomaticAtom(
        _ candidate: MemoryAtom,
        now: Date = Date()
    ) throws -> MemoryAtom {
        let statement = candidate.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { return candidate }

        var automatic = candidate
        automatic.statement = statement
        automatic.status = candidate.status == .pending ? .pending : .active
        automatic.authority = candidate.authority
        automatic.updatedAt = now
        automatic.normalizedKey = automatic.normalizedKey
            ?? MemoryGraphWriter.normalizedKey(type: automatic.type, statement: statement)
        if automatic.embedding == nil {
            automatic.embedding = embed(statement)
        }

        var stored = automatic
        try nodeStore.inTransaction {
            let matching = try matchingLifecycleAtom(for: automatic)
            if let matching, matching.status == .archived {
                stored = matching
                return
            }

            try recordAutomaticObservation(for: automatic, now: now)
            if let conflict = try conflictingDurableAtom(for: automatic) {
                try nodeStore.insertMemoryAtom(automatic)
                var conflicted = conflict
                conflicted.status = .conflicted
                conflicted.updatedAt = now
                try nodeStore.updateMemoryAtom(conflicted)
                try nodeStore.insertMemoryTension(MemoryTension(
                    kind: .durableConflict,
                    existingAtomId: conflict.id,
                    challengerAtomId: automatic.id,
                    summary: "Automatic memory challenged durable memory: \(conflict.statement)",
                    createdAt: now
                ))
                stored = automatic
                return
            }

            if var existing = matching {
                existing.statement = automatic.statement
                existing.confidence = max(existing.confidence, automatic.confidence)
                existing.updatedAt = now
                existing.lastSeenAt = Self.maxDate(existing.lastSeenAt, now)
                existing.sourceNodeId = existing.sourceNodeId ?? automatic.sourceNodeId
                existing.sourceMessageId = existing.sourceMessageId ?? automatic.sourceMessageId
                existing.evidenceQuote = existing.evidenceQuote ?? automatic.evidenceQuote
                existing.captureReason = existing.captureReason ?? automatic.captureReason
                existing.correctsTarget = automatic.correctsTarget ?? existing.correctsTarget
                existing.embedding = existing.embedding ?? automatic.embedding
                existing.authority = try promotedAuthorityIfEligible(for: existing, now: now)
                if existing.authority == .durable {
                    existing.confidence = max(existing.confidence, 0.86)
                }
                try nodeStore.updateMemoryAtom(existing)
                stored = existing
            } else {
                automatic.authority = try promotedAuthorityIfEligible(for: automatic, now: now)
                if automatic.authority == .durable {
                    automatic.confidence = max(automatic.confidence, 0.86)
                }
                try nodeStore.insertMemoryAtom(automatic)
                stored = automatic
            }
        }
        return stored
    }

    @discardableResult
    func reject(_ atomId: UUID, now: Date = Date()) throws -> MemoryAtom? {
        var rejected: MemoryAtom?
        try nodeStore.inTransaction {
            guard var atom = try nodeStore.fetchMemoryAtom(id: atomId) else { return }
            guard atom.status == .pending else {
                rejected = atom
                return
            }
            atom.status = .archived
            atom.updatedAt = now
            try nodeStore.updateMemoryAtom(atom)
            try syncMirroredFactLifecycle(for: atom, status: .archived, now: now)
            rejected = atom
        }
        return rejected
    }

    @discardableResult
    func resolveTension(_ tensionId: UUID, now: Date = Date()) throws -> MemoryTension? {
        var resolved: MemoryTension?
        try nodeStore.inTransaction {
            guard var tension = try nodeStore.fetchMemoryTensions()
                .first(where: { $0.id == tensionId })
            else {
                return
            }
            tension.status = .resolved
            tension.resolvedAt = now
            try nodeStore.updateMemoryTension(tension)
            resolved = tension
        }
        return resolved
    }

    @discardableResult
    func forget(_ atomId: UUID) throws -> Bool {
        var didForget = false
        try nodeStore.inTransaction {
            guard let atom = try nodeStore.fetchMemoryAtom(id: atomId) else { return }
            try deleteMirroredFacts(for: atom)
            try nodeStore.deleteMemoryAtomInCurrentTransaction(id: atomId)
            didForget = true
        }
        return didForget
    }

    private func applyApprovalSideEffects(for atom: MemoryAtom, now: Date) throws {
        try approveDecisionChainIfNeeded(anchor: atom, now: now)

        guard atom.type == .correction,
              let correctsTarget = atom.correctsTarget?.trimmingCharacters(in: .whitespacesAndNewlines),
              !correctsTarget.isEmpty
        else { return }

        let writer = MemoryGraphWriter(nodeStore: nodeStore, embed: embed)
        var atoms = try nodeStore.fetchMemoryAtoms()
        var edges = try nodeStore.fetchMemoryEdges()
        var result = MemoryGraphWriteResult()
        try writer.supersedeMatchingClaims(
            matching: correctsTarget,
            targetTypes: [.belief, .preference, .goal, .plan, .rule],
            superseder: atom,
            confidence: atom.confidence,
            now: now,
            atoms: &atoms,
            edges: &edges,
            result: &result
        )
    }

    private func syncMirroredFactLifecycle(
        for atom: MemoryAtom,
        status: MemoryStatus,
        now: Date
    ) throws {
        for var fact in try mirroredFactEntries(for: atom) where fact.status != status {
            fact.status = status
            fact.updatedAt = now
            if status == .active {
                fact.confidence = max(fact.confidence, atom.confidence)
            }
            try nodeStore.updateMemoryFactEntry(fact)
        }
    }

    private func deleteMirroredFacts(for atom: MemoryAtom) throws {
        for fact in try mirroredFactEntries(for: atom) {
            try nodeStore.deleteMemoryFactEntry(id: fact.id)
        }
    }

    private func mirroredFactEntries(for atom: MemoryAtom) throws -> [MemoryFactEntry] {
        try nodeStore.fetchMemoryFactEntries().filter { fact in
            Self.mirrorsFactEntry(fact, atom: atom)
        }
    }

    private static func mirrorsFactEntry(_ fact: MemoryFactEntry, atom: MemoryAtom) -> Bool {
        guard let factAtom = MemoryGraphAtomMapper.atom(fromFact: fact, now: atom.updatedAt),
              factAtom.type == atom.type,
              factAtom.scope == atom.scope,
              factAtom.scopeRefId == atom.scopeRefId
        else { return false }

        if let factKey = factAtom.normalizedKey,
           let atomKey = atom.normalizedKey,
           factKey == atomKey {
            return true
        }

        return MemoryGraphAtomMapper.normalizedLine(factAtom.statement)
            == MemoryGraphAtomMapper.normalizedLine(atom.statement)
    }

    private func triggerAutomaticReflectionIfNeeded(afterApproving atom: MemoryAtom, now: Date) throws {
        guard automaticReflectionMinimumSources > 1,
              automaticReflectionSourceLimit > 0,
              MemoryReflectionEngine.isAutomaticReflectionSource(atom),
              Self.isCurrentlyValid(atom, now: now),
              try !hasPendingReflectionProposal(),
              let context = try automaticReflectionContext(for: atom)
        else { return }

        _ = try MemoryReflectionEngine(
            nodeStore: nodeStore,
            embed: embed,
            synthesizeInsight: reflectionSynthesizeInsight
        ).proposeFromActiveMemory(
            projectId: context.projectId,
            conversationId: context.conversationId,
            sourceLimit: automaticReflectionSourceLimit,
            minimumSources: automaticReflectionMinimumSources,
            now: now
        )
    }

    private func automaticReflectionContext(for atom: MemoryAtom) throws -> (projectId: UUID?, conversationId: UUID?)? {
        switch atom.scope {
        case .global:
            return (nil, nil)
        case .project:
            guard let projectId = atom.scopeRefId else { return nil }
            return (projectId, nil)
        case .conversation:
            guard let conversationId = atom.scopeRefId else { return nil }
            let projectId = try nodeStore.fetchNode(id: conversationId)?.projectId
            return (projectId, conversationId)
        case .selfReflection:
            return nil
        }
    }

    private func hasPendingReflectionProposal() throws -> Bool {
        try !nodeStore.fetchMemoryAtoms(
            types: [.insight],
            statuses: [.pending],
            scope: .selfReflection,
            scopeRefId: nil,
            eventTimeStart: nil,
            eventTimeEnd: nil,
            limit: 1
        ).isEmpty
    }

    private func approveDecisionChainIfNeeded(anchor atom: MemoryAtom, now: Date) throws {
        guard let rejection = try decisionChainRejection(for: atom),
              let chain = try MemoryGraphStore(nodeStore: nodeStore).decisionChain(for: rejection.id)
        else { return }

        var activeRejection = chain.rejection
        let chainAtoms = ([chain.rejection, chain.rejectedProposal, chain.replacement].compactMap { $0 } + chain.reasons)
        for var chainAtom in chainAtoms where chainAtom.status == .pending {
            chainAtom.status = .active
            chainAtom.updatedAt = now
            chainAtom.lastSeenAt = now
            try nodeStore.updateMemoryAtom(chainAtom)
            if chainAtom.id == rejection.id {
                activeRejection = chainAtom
            }
        }

        guard let rejectedProposal = chain.rejectedProposal?.statement else { return }
        let writer = MemoryGraphWriter(nodeStore: nodeStore, embed: embed)
        var atoms = try nodeStore.fetchMemoryAtoms()
        var edges = try nodeStore.fetchMemoryEdges()
        var result = MemoryGraphWriteResult()
        try writer.supersedeMatchingClaims(
            matching: rejectedProposal,
            targetTypes: [.currentPosition, .decision],
            superseder: activeRejection,
            confidence: activeRejection.confidence,
            now: now,
            atoms: &atoms,
            edges: &edges,
            result: &result
        )
    }

    private func decisionChainRejection(for atom: MemoryAtom) throws -> MemoryAtom? {
        if atom.type == .rejection {
            return atom
        }

        let incoming = try nodeStore.fetchMemoryEdges(toAtomId: atom.id)
        if let direct = incoming.first(where: { $0.type == .rejected || $0.type == .because }) {
            return try nodeStore.fetchMemoryAtom(id: direct.fromAtomId)
        }

        guard atom.type == .currentPosition else { return nil }
        for edge in incoming where edge.type == .replacedBy {
            let proposalId = edge.fromAtomId
            let proposalIncoming = try nodeStore.fetchMemoryEdges(toAtomId: proposalId)
            if let rejected = proposalIncoming.first(where: { $0.type == .rejected }) {
                return try nodeStore.fetchMemoryAtom(id: rejected.fromAtomId)
            }
        }
        return nil
    }

    func hybridRecall(
        currentMessage: String,
        projectId: UUID?,
        conversationId: UUID,
        queryEmbedding: [Float]? = nil,
        limit: Int = 4,
        now: Date = Date()
    ) throws -> [MemoryHybridRecallResult] {
        guard limit > 0 else { return [] }
        let query = currentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let atoms = try nodeStore.fetchMemoryAtoms(
            types: [],
            statuses: [.active],
            scope: nil,
            scopeRefId: nil,
            eventTimeStart: nil,
            eventTimeEnd: nil,
            limit: nil
        )
        .filter {
            Self.isCurrentlyValid($0, now: now)
                && isInRecallScope($0, projectId: projectId, conversationId: conversationId)
        }

        guard !atoms.isEmpty else { return [] }

        let semanticByAtomId = Dictionary(uniqueKeysWithValues: atoms.map { atom in
            (atom.id, Self.semanticScore(query: query, queryEmbedding: queryEmbedding, atom: atom))
        })
        let seedIds = Set(
            semanticByAtomId
                .sorted { $0.value > $1.value }
                .prefix(3)
                .filter { $0.value >= 0.50 }
                .map(\.key)
        )
        let edges = try nodeStore.fetchMemoryEdges()

        return atoms.compactMap { atom -> MemoryHybridRecallResult? in
            let score = MemoryHybridRecallScore(
                semantic: semanticByAtomId[atom.id] ?? 0,
                graph: Self.graphScore(atomId: atom.id, seedIds: seedIds, edges: edges),
                recency: Self.recencyScore(atom: atom, now: now),
                importance: Self.clamp01(atom.confidence),
                interaction: Self.interactionScore(atom: atom, now: now)
            )
            guard score.final >= 0.20 else { return nil }
            return MemoryHybridRecallResult(
                atom: atom,
                score: score,
                reason: Self.reason(for: atom, score: score)
            )
        }
        .sorted {
            if $0.score.final == $1.score.final {
                return ($0.atom.lastSeenAt ?? $0.atom.updatedAt) > ($1.atom.lastSeenAt ?? $1.atom.updatedAt)
            }
            return $0.score.final > $1.score.final
        }
        .prefix(limit)
        .map { $0 }
    }

    private func isInRecallScope(_ atom: MemoryAtom, projectId: UUID?, conversationId: UUID) -> Bool {
        switch atom.scope {
        case .global:
            return true
        case .project:
            return atom.scopeRefId == projectId
        case .conversation:
            guard let scopeRefId = atom.scopeRefId else { return false }
            if scopeRefId == conversationId { return true }
            guard let projectId else { return true }
            guard let sourceNode = try? nodeStore.fetchNode(id: scopeRefId) else { return false }
            return sourceNode.projectId == projectId
        case .selfReflection:
            return true
        }
    }

    private func matchingLifecycleAtom(for proposal: MemoryAtom) throws -> MemoryAtom? {
        let atoms = try nodeStore.fetchMemoryAtoms(
            types: [proposal.type],
            statuses: [.active, .pending, .archived],
            scope: proposal.scope,
            scopeRefId: proposal.scopeRefId,
            eventTimeStart: nil,
            eventTimeEnd: nil,
            limit: nil
        )
        let matches = atoms.filter { Self.matches($0, proposal: proposal) }
        return matches.first { $0.status == .active }
            ?? matches.first { $0.status == .pending }
            ?? matches.first { $0.status == .archived }
    }

    private static func atomType(for kind: MemoryKind?, statement: String) -> MemoryAtomType {
        switch kind {
        case .identity:
            return .identity
        case .preference:
            return .preference
        case .constraint:
            return .constraint
        case .decision:
            return .decision
        case .boundary:
            return .boundary
        case .relationship:
            return .entity
        case .thread, .temporaryContext:
            return .event
        case .none:
            let normalized = statement.lowercased()
            if normalized.contains("rule") || normalized.contains("原则") || normalized.contains("原則") {
                return .rule
            }
            if normalized.contains("goal") || normalized.contains("目标") || normalized.contains("目標") {
                return .goal
            }
            if normalized.contains("plan") || normalized.contains("计划") || normalized.contains("計劃") {
                return .plan
            }
            return .event
        }
    }

    private static func temporalScope(for type: MemoryAtomType) -> MemoryTemporalScope {
        switch type {
        case .event, .decision, .proposal, .rejection, .reason, .correction, .task, .currentPosition:
            return .episodic
        case .identity, .preference, .boundary, .constraint, .belief, .entity, .goal, .plan:
            return .semantic
        case .rule:
            return .procedural
        case .pattern, .insight:
            return .reflective
        }
    }

    private static func storageScope(for type: MemoryAtomType, projectId: UUID?) -> MemoryScope {
        switch type {
        case .identity, .preference, .boundary, .constraint, .rule:
            return .global
        case .goal, .plan, .task, .currentPosition:
            return projectId == nil ? .conversation : .project
        case .pattern, .insight:
            return .selfReflection
        case .event, .proposal, .decision, .rejection, .reason, .belief, .correction, .entity:
            return .conversation
        }
    }

    private static func confidence(for lifecycle: MemoryCurationLifecycle) -> Double {
        switch lifecycle {
        case .stable:
            return 0.72
        case .ephemeral:
            return 0.35
        case .rejected:
            return 0
        case .consentRequired:
            return 0.2
        }
    }

    private static func cleanStatement(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let markers = [
            "remember that ",
            "remember this: ",
            "記住",
            "记住",
            "記低",
            "记低"
        ]
        for marker in markers where lower.hasPrefix(marker) {
            text.removeFirst(marker.count)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func semanticScore(
        query: String,
        queryEmbedding: [Float]?,
        atom: MemoryAtom
    ) -> Double {
        if let queryEmbedding,
           let embedding = atom.embedding,
           queryEmbedding.count == embedding.count,
           !queryEmbedding.isEmpty {
            return clamp01(Double(cosine(queryEmbedding, embedding)))
        }
        return lexicalScore(query: query, text: atom.statement)
    }

    private static func graphScore(
        atomId: UUID,
        seedIds: Set<UUID>,
        edges: [MemoryEdge]
    ) -> Double {
        if seedIds.contains(atomId) { return 1 }
        let weights = edges.compactMap { edge -> Double? in
            if edge.fromAtomId == atomId, seedIds.contains(edge.toAtomId) {
                return edge.weight
            }
            if edge.toAtomId == atomId, seedIds.contains(edge.fromAtomId) {
                return edge.weight
            }
            return nil
        }
        return clamp01(weights.max() ?? 0)
    }

    private static func recencyScore(atom: MemoryAtom, now: Date) -> Double {
        let reference = atom.lastSeenAt ?? atom.eventTime ?? atom.updatedAt
        let ageDays = max(0, now.timeIntervalSince(reference) / 86_400)
        return clamp01(pow(0.5, ageDays / 45))
    }

    private static func interactionScore(atom: MemoryAtom, now: Date) -> Double {
        guard let lastSeenAt = atom.lastSeenAt else { return 0 }
        let ageDays = max(0, now.timeIntervalSince(lastSeenAt) / 86_400)
        return clamp01(pow(0.5, ageDays / 14))
    }

    private static func isCurrentlyValid(_ atom: MemoryAtom, now: Date) -> Bool {
        if let validFrom = atom.validFrom, validFrom > now { return false }
        if let validUntil = atom.validUntil, validUntil < now { return false }
        return true
    }

    private static func lexicalScore(query: String, text: String) -> Double {
        let queryTokens = tokens(query)
        let textTokens = tokens(text)
        guard !queryTokens.isEmpty, !textTokens.isEmpty else { return 0 }
        let intersection = Set(queryTokens).intersection(textTokens).count
        let union = Set(queryTokens).union(textTokens).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dot: Float = 0
        var leftNorm: Float = 0
        var rightNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftNorm += lhs[index] * lhs[index]
            rightNorm += rhs[index] * rhs[index]
        }
        guard leftNorm > 0, rightNorm > 0 else { return 0 }
        return dot / (sqrt(leftNorm) * sqrt(rightNorm))
    }

    private static func reason(for atom: MemoryAtom, score: MemoryHybridRecallScore) -> String {
        [
            String(format: "semantic=%.2f", score.semantic),
            String(format: "graph=%.2f", score.graph),
            String(format: "recency=%.2f", score.recency),
            String(format: "importance=%.2f", score.importance),
            String(format: "interaction=%.2f", score.interaction),
            String(format: "final=%.2f", score.final),
            "authority=\(atom.authority.rawValue)",
            "source_node_id=\(atom.sourceNodeId?.uuidString ?? "missing")",
            "source_message_id=\(atom.sourceMessageId?.uuidString ?? "missing")"
        ].joined(separator: " ")
    }

    private static func matches(_ atom: MemoryAtom, proposal: MemoryAtom) -> Bool {
        guard atom.type == proposal.type,
              atom.scope == proposal.scope,
              atom.scopeRefId == proposal.scopeRefId
        else { return false }

        if let atomKey = atom.normalizedKey,
           let proposalKey = proposal.normalizedKey,
           atomKey == proposalKey {
            return true
        }

        return MemoryGraphAtomMapper.normalizedLine(atom.statement)
            == MemoryGraphAtomMapper.normalizedLine(proposal.statement)
    }

    private func recordAutomaticObservation(for atom: MemoryAtom, now: Date) throws {
        let key = atom.normalizedKey ?? MemoryGraphWriter.normalizedKey(type: atom.type, statement: atom.statement)
        try nodeStore.insertMemoryObservation(MemoryObservation(
            rawText: key,
            extractedType: atom.type,
            confidence: atom.confidence,
            sourceNodeId: atom.sourceNodeId,
            sourceMessageId: atom.sourceMessageId,
            createdAt: now
        ))
    }

    private func promotedAuthorityIfEligible(for atom: MemoryAtom, now: Date) throws -> MemoryAuthority {
        guard atom.authority == .tentative,
              atom.status == .active,
              let key = atom.normalizedKey,
              try !hasOpenTension(for: atom.id)
        else {
            return atom.authority
        }
        let matchingObservations = try nodeStore.fetchMemoryObservations().filter { observation in
            observation.extractedType == atom.type &&
                MemoryGraphAtomMapper.normalizedLine(observation.rawText) == MemoryGraphAtomMapper.normalizedLine(key)
        }
        let uniqueMessageIds = Set(matchingObservations.compactMap(\.sourceMessageId))
        let uniqueNodeIds = Set(matchingObservations.compactMap(\.sourceNodeId))
        return uniqueMessageIds.count >= 3 && uniqueNodeIds.count >= 2 ? .durable : .tentative
    }

    private func hasOpenTension(for atomId: UUID) throws -> Bool {
        try nodeStore.fetchMemoryTensions(statuses: [.open]).contains { tension in
            tension.existingAtomId == atomId || tension.challengerAtomId == atomId
        }
    }

    private func conflictingDurableAtom(for candidate: MemoryAtom) throws -> MemoryAtom? {
        guard candidate.authority == .tentative,
              candidate.status == .active,
              candidate.type == .correction || candidate.correctsTarget != nil
        else { return nil }
        let target = candidate.correctsTarget.map(MemoryGraphAtomMapper.normalizedLine) ?? ""
        return try nodeStore.fetchMemoryAtoms(
            types: [],
            statuses: [.active],
            scope: candidate.scope,
            scopeRefId: candidate.scopeRefId,
            eventTimeStart: nil,
            eventTimeEnd: nil,
            limit: nil
        )
        .first { atom in
            atom.authority == .durable &&
                atom.id != candidate.id &&
                (
                    (!target.isEmpty && MemoryGraphAtomMapper.normalizedLine(atom.statement).contains(target)) ||
                    (atom.normalizedKey != nil && atom.normalizedKey == candidate.normalizedKey && atom.statement != candidate.statement)
                )
        }
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
