import Foundation

struct MemoryGraphWriteResult: Equatable {
    var insertedAtoms = 0
    var updatedAtoms = 0
    var unchangedAtoms = 0
    var insertedEdges = 0
}

struct MemoryGraphDecisionChainInput {
    let rejectedProposal: String
    let rejection: String
    let reasons: [String]
    let replacement: String?
    let confidence: Double
    let scope: MemoryScope
    let scopeRefId: UUID?
    let eventTime: Date?
    let sourceNodeId: UUID?
    let sourceMessageId: UUID?
    let now: Date
}

final class MemoryGraphWriter {
    private let nodeStore: NodeStore
    private let embed: (String) -> [Float]?

    init(
        nodeStore: NodeStore,
        embed: @escaping (String) -> [Float]? = { _ in nil }
    ) {
        self.nodeStore = nodeStore
        self.embed = embed
    }

    @discardableResult
    func upsertAtom(
        _ candidate: MemoryAtom,
        atoms: inout [MemoryAtom],
        result: inout MemoryGraphWriteResult
    ) throws -> MemoryAtom {
        if let index = atoms.firstIndex(where: { Self.matches($0, candidate: candidate) }) {
            let existing = atoms[index]
            var enriched = candidate
            // Re-embed only when the statement changed; otherwise reuse the
            // existing embedding to avoid redundant model calls per refresh.
            if existing.statement != candidate.statement,
               let fresh = embed(candidate.statement) {
                enriched.embedding = fresh
            }
            let merged = Self.merged(existing: existing, candidate: enriched)
            if Self.hasMeaningfulChange(existing, merged) {
                try nodeStore.updateMemoryAtom(merged)
                atoms[index] = merged
                result.updatedAtoms += 1
            } else {
                result.unchangedAtoms += 1
            }
            return merged
        }

        var enriched = candidate
        if enriched.embedding == nil, let fresh = embed(candidate.statement) {
            enriched.embedding = fresh
        }
        try nodeStore.insertMemoryAtom(enriched)
        atoms.append(enriched)
        result.insertedAtoms += 1
        return enriched
    }

    func link(
        from fromAtomId: UUID,
        to toAtomId: UUID,
        type: MemoryEdgeType,
        weight: Double,
        sourceMessageId: UUID?,
        createdAt: Date,
        edges: inout [MemoryEdge],
        result: inout MemoryGraphWriteResult
    ) throws {
        guard edges.first(where: {
            $0.fromAtomId == fromAtomId && $0.toAtomId == toAtomId && $0.type == type
        }) == nil else {
            return
        }

        let edge = MemoryEdge(
            fromAtomId: fromAtomId,
            toAtomId: toAtomId,
            type: type,
            weight: weight,
            createdAt: createdAt,
            sourceMessageId: sourceMessageId
        )
        try nodeStore.insertMemoryEdge(edge)
        edges.append(edge)
        result.insertedEdges += 1
    }

    func writeDecisionChain(
        _ input: MemoryGraphDecisionChainInput,
        atoms: inout [MemoryAtom],
        edges: inout [MemoryEdge],
        result: inout MemoryGraphWriteResult
    ) throws {
        let proposal = atom(
            type: .proposal,
            statement: input.rejectedProposal,
            input: input
        )
        let rejection = atom(
            type: .rejection,
            statement: input.rejection,
            input: input
        )

        let proposalAtom = try upsertAtom(proposal, atoms: &atoms, result: &result)
        let rejectionAtom = try upsertAtom(rejection, atoms: &atoms, result: &result)
        try link(
            from: rejectionAtom.id,
            to: proposalAtom.id,
            type: .rejected,
            weight: input.confidence,
            sourceMessageId: input.sourceMessageId,
            createdAt: input.now,
            edges: &edges,
            result: &result
        )

        try supersedePriorPositions(
            rejectedProposalText: input.rejectedProposal,
            newRejection: rejectionAtom,
            input: input,
            atoms: &atoms,
            edges: &edges,
            result: &result
        )

        for reasonText in input.reasons {
            let reason = atom(
                type: .reason,
                statement: reasonText,
                input: input
            )
            let reasonAtom = try upsertAtom(reason, atoms: &atoms, result: &result)
            try link(
                from: rejectionAtom.id,
                to: reasonAtom.id,
                type: .because,
                weight: input.confidence,
                sourceMessageId: input.sourceMessageId,
                createdAt: input.now,
                edges: &edges,
                result: &result
            )
        }

        if let replacementText = input.replacement {
            let replacement = atom(
                type: .currentPosition,
                statement: replacementText,
                input: input
            )
            let replacementAtom = try upsertAtom(replacement, atoms: &atoms, result: &result)
            try link(
                from: proposalAtom.id,
                to: replacementAtom.id,
                type: .replacedBy,
                weight: input.confidence,
                sourceMessageId: input.sourceMessageId,
                createdAt: input.now,
                edges: &edges,
                result: &result
            )
        }
    }

    /// Generic supersede: flip every active-or-archived atom in the
    /// superseder's scope+scopeRefId whose normalized statement matches
    /// `targetText` AND whose type is in `targetTypes` to `superseded`,
    /// and write a `supersedes` edge from the superseder to it. This is
    /// the building block re-used by both decision-chain rejections and
    /// correction-driven retractions of prior beliefs/preferences. Cross-
    /// scope is intentionally not handled here — that needs a dedicated
    /// promotion flow.
    func supersedeMatchingClaims(
        matching targetText: String,
        targetTypes: Set<MemoryAtomType>,
        superseder: MemoryAtom,
        confidence: Double,
        now: Date,
        atoms: inout [MemoryAtom],
        edges: inout [MemoryEdge],
        result: inout MemoryGraphWriteResult
    ) throws {
        let normalizedTarget = MemoryGraphAtomMapper.normalizedLine(targetText)
        guard !normalizedTarget.isEmpty else { return }
        let candidateStatuses: Set<MemoryStatus> = [.active, .archived]

        for index in atoms.indices {
            let candidate = atoms[index]
            guard targetTypes.contains(candidate.type),
                  candidateStatuses.contains(candidate.status),
                  candidate.scope == superseder.scope,
                  candidate.scopeRefId == superseder.scopeRefId,
                  candidate.id != superseder.id,
                  MemoryGraphAtomMapper.normalizedLine(candidate.statement) == normalizedTarget
            else { continue }

            var superseded = candidate
            superseded.status = .superseded
            superseded.updatedAt = now
            try nodeStore.updateMemoryAtom(superseded)
            atoms[index] = superseded
            result.updatedAtoms += 1

            try link(
                from: superseder.id,
                to: candidate.id,
                type: .supersedes,
                weight: confidence,
                sourceMessageId: superseder.sourceMessageId,
                createdAt: now,
                edges: &edges,
                result: &result
            )
        }
    }

    /// When Alex's new chain rejects a proposal that matches a prior
    /// `decision` or `currentPosition` he already held in the same scope,
    /// flip the prior atom's lifecycle to `superseded` and write a
    /// `supersedes` edge from the new rejection to it. This is the only
    /// thing that lets future recall answer "when did I change my mind?"
    /// — without it, the old position and the new rejection coexist as
    /// equally-active claims (the audit's exact "fake memory" failure).
    /// Includes `archived` candidates because the surrounding refresh flow
    /// archives extraction atoms before chains run; an archived atom that
    /// matches a fresh rejection deserves the stronger `superseded` label.
    /// Scope is intentionally narrow (same scope + scopeRefId): cross-scope
    /// resolution belongs to a dedicated promotion step, not a per-chain
    /// write.
    private func supersedePriorPositions(
        rejectedProposalText: String,
        newRejection: MemoryAtom,
        input: MemoryGraphDecisionChainInput,
        atoms: inout [MemoryAtom],
        edges: inout [MemoryEdge],
        result: inout MemoryGraphWriteResult
    ) throws {
        let normalizedRejected = MemoryGraphAtomMapper.normalizedLine(rejectedProposalText)
        guard !normalizedRejected.isEmpty else { return }
        let supersedeTargetTypes: Set<MemoryAtomType> = [.currentPosition, .decision]
        let candidateStatuses: Set<MemoryStatus> = [.active, .archived]

        for index in atoms.indices {
            let candidate = atoms[index]
            guard supersedeTargetTypes.contains(candidate.type),
                  candidateStatuses.contains(candidate.status),
                  candidate.scope == input.scope,
                  candidate.scopeRefId == input.scopeRefId,
                  candidate.id != newRejection.id,
                  MemoryGraphAtomMapper.normalizedLine(candidate.statement) == normalizedRejected
            else { continue }

            var superseded = candidate
            superseded.status = .superseded
            superseded.updatedAt = input.now
            try nodeStore.updateMemoryAtom(superseded)
            atoms[index] = superseded
            result.updatedAtoms += 1

            try link(
                from: newRejection.id,
                to: candidate.id,
                type: .supersedes,
                weight: input.confidence,
                sourceMessageId: input.sourceMessageId,
                createdAt: input.now,
                edges: &edges,
                result: &result
            )
        }
    }

    private func atom(
        type: MemoryAtomType,
        statement: String,
        input: MemoryGraphDecisionChainInput
    ) -> MemoryAtom {
        MemoryAtom(
            type: type,
            statement: statement,
            normalizedKey: Self.normalizedKey(type: type, statement: statement),
            scope: input.scope,
            scopeRefId: input.scopeRefId,
            status: .active,
            confidence: input.confidence,
            eventTime: input.eventTime,
            createdAt: input.now,
            updatedAt: input.now,
            lastSeenAt: input.now,
            sourceNodeId: input.sourceNodeId,
            sourceMessageId: input.sourceMessageId
        )
    }

    static func normalizedKey(type: MemoryAtomType, statement: String) -> String {
        "\(type.rawValue)|\(MemoryGraphAtomMapper.normalizedLine(statement))"
    }

    private static func matches(_ atom: MemoryAtom, candidate: MemoryAtom) -> Bool {
        guard atom.scope == candidate.scope,
              atom.scopeRefId == candidate.scopeRefId,
              atom.type == candidate.type
        else { return false }

        if let atomKey = atom.normalizedKey,
           let candidateKey = candidate.normalizedKey,
           atomKey == candidateKey {
            return true
        }

        return MemoryGraphAtomMapper.normalizedLine(atom.statement)
            == MemoryGraphAtomMapper.normalizedLine(candidate.statement)
    }

    private static func merged(existing: MemoryAtom, candidate: MemoryAtom) -> MemoryAtom {
        var merged = existing
        merged.type = candidate.type
        merged.statement = candidate.statement
        merged.normalizedKey = candidate.normalizedKey ?? existing.normalizedKey
        merged.scope = candidate.scope
        merged.scopeRefId = candidate.scopeRefId
        merged.status = candidate.status
        merged.confidence = max(existing.confidence, candidate.confidence)
        merged.eventTime = existing.eventTime ?? candidate.eventTime
        merged.validFrom = existing.validFrom ?? candidate.validFrom
        merged.validUntil = candidate.validUntil ?? existing.validUntil
        merged.updatedAt = max(existing.updatedAt, candidate.updatedAt)
        merged.lastSeenAt = maxDate(existing.lastSeenAt, candidate.lastSeenAt)
        merged.sourceNodeId = existing.sourceNodeId ?? candidate.sourceNodeId
        merged.sourceMessageId = existing.sourceMessageId ?? candidate.sourceMessageId
        merged.embedding = existing.embedding ?? candidate.embedding
        return merged
    }

    private static func hasMeaningfulChange(_ lhs: MemoryAtom, _ rhs: MemoryAtom) -> Bool {
        lhs.type != rhs.type
            || lhs.statement != rhs.statement
            || lhs.normalizedKey != rhs.normalizedKey
            || lhs.scope != rhs.scope
            || lhs.scopeRefId != rhs.scopeRefId
            || lhs.status != rhs.status
            || lhs.confidence != rhs.confidence
            || lhs.eventTime != rhs.eventTime
            || lhs.validFrom != rhs.validFrom
            || lhs.validUntil != rhs.validUntil
            || lhs.updatedAt != rhs.updatedAt
            || lhs.lastSeenAt != rhs.lastSeenAt
            || lhs.sourceNodeId != rhs.sourceNodeId
            || lhs.sourceMessageId != rhs.sourceMessageId
            || lhs.embedding != rhs.embedding
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.none, .none):
            return nil
        case (.some(let lhs), .none):
            return lhs
        case (.none, .some(let rhs)):
            return rhs
        case (.some(let lhs), .some(let rhs)):
            return max(lhs, rhs)
        }
    }
}
