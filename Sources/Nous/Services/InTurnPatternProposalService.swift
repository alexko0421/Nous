import Foundation

enum InTurnPatternProposalIgnoreReason: Equatable {
    case belowHighConfidenceThreshold
}

enum InTurnPatternProposalResult: Equatable {
    case ignored(reason: InTurnPatternProposalIgnoreReason)
    case recorded(evidenceCount: Int, daySpan: Double)
    case staged(MemoryAtom, evidenceMessageIds: [UUID])
    case suppressedByRejectedProposal(MemoryAtom)
}

struct InTurnPatternEvidenceDigest: Equatable {
    let kind: InTurnPatternKind
    let statement: String
    let suggestedAction: String
    let proposalAtomId: UUID?
    let proposalStatus: MemoryStatus?
    let messageIds: [UUID]
    let evidenceCount: Int
    let averageConfidence: Double
    let firstSeen: Date
    let lastSeen: Date
}

final class InTurnPatternProposalService {
    private let nodeStore: NodeStore
    private let lifecycleFactory: () -> MemoryLifecycleEngine
    private let highConfidenceThreshold: Double
    private let minimumIndependentTurns: Int
    private let minimumSpan: TimeInterval

    init(
        nodeStore: NodeStore,
        lifecycleFactory: (() -> MemoryLifecycleEngine)? = nil,
        highConfidenceThreshold: Double = 0.85,
        minimumIndependentTurns: Int = 3,
        minimumSpan: TimeInterval = 7 * 86_400
    ) {
        self.nodeStore = nodeStore
        self.lifecycleFactory = lifecycleFactory ?? { MemoryLifecycleEngine(nodeStore: nodeStore) }
        self.highConfidenceThreshold = highConfidenceThreshold
        self.minimumIndependentTurns = minimumIndependentTurns
        self.minimumSpan = minimumSpan
    }

    @discardableResult
    func record(
        signal: InTurnPatternSignal,
        sourceNodeId: UUID,
        sourceMessageId: UUID,
        projectId: UUID?,
        now: Date = Date(),
        userConfirmed: Bool = false
    ) throws -> InTurnPatternProposalResult {
        guard signal.confidence >= highConfidenceThreshold else {
            return .ignored(reason: .belowHighConfidenceThreshold)
        }

        if let rejected = try matchingPatternAtom(for: signal.kind, statuses: [.archived]) {
            return .suppressedByRejectedProposal(rejected)
        }

        let key = Self.observationKey(for: signal.kind)
        let existing = try patternObservations(for: signal.kind)
        if !existing.contains(where: { $0.sourceMessageId == sourceMessageId }) {
            try nodeStore.insertMemoryObservation(MemoryObservation(
                rawText: key,
                extractedType: .pattern,
                confidence: signal.confidence,
                sourceNodeId: sourceNodeId,
                sourceMessageId: sourceMessageId,
                createdAt: now
            ))
        }

        let observations = try patternObservations(for: signal.kind)
        let evidence = Self.uniqueMessageEvidence(from: observations)
        let span = Self.daySpan(for: evidence)
        guard evidence.count >= minimumIndependentTurns,
              userConfirmed || Self.timeSpan(for: evidence) >= minimumSpan
        else {
            return .recorded(evidenceCount: evidence.count, daySpan: span)
        }

        let proposal = patternAtom(
            for: signal.kind,
            confidence: min(0.95, max(signal.confidence, Self.averageConfidence(for: evidence))),
            sourceNodeId: sourceNodeId,
            sourceMessageId: sourceMessageId,
            now: now
        )
        let stored = try lifecycleFactory().stageAtomProposal(proposal, now: now)
        if stored.status == .archived {
            return .suppressedByRejectedProposal(stored)
        }
        return .staged(stored, evidenceMessageIds: evidence.compactMap(\.sourceMessageId))
    }

    func patternEvidenceContext(
        projectId: UUID?,
        weekStart: Date,
        weekEnd: Date
    ) throws -> [InTurnPatternEvidenceDigest] {
        try Self.supportedKinds.compactMap { kind in
            guard let atom = try matchingPatternAtom(for: kind, statuses: [.pending, .active]) else {
                return nil
            }
            let observations = try patternObservations(for: kind).filter { observation in
                observation.createdAt >= weekStart
                    && observation.createdAt < weekEnd
                    && projectMatches(observation.sourceNodeId, projectId: projectId)
            }
            let evidence = Self.uniqueMessageEvidence(from: observations)
            guard evidence.count >= minimumIndependentTurns,
                  let firstSeen = evidence.first?.createdAt,
                  let lastSeen = evidence.last?.createdAt
            else {
                return nil
            }
            return InTurnPatternEvidenceDigest(
                kind: kind,
                statement: atom.statement,
                suggestedAction: kind.pairedAction,
                proposalAtomId: atom.id,
                proposalStatus: atom.status,
                messageIds: evidence.compactMap(\.sourceMessageId),
                evidenceCount: evidence.count,
                averageConfidence: Self.averageConfidence(for: evidence),
                firstSeen: firstSeen,
                lastSeen: lastSeen
            )
        }
    }

    private func patternAtom(
        for kind: InTurnPatternKind,
        confidence: Double,
        sourceNodeId: UUID,
        sourceMessageId: UUID,
        now: Date
    ) -> MemoryAtom {
        MemoryAtom(
            type: .pattern,
            statement: Self.proposalStatement(for: kind),
            normalizedKey: Self.observationKey(for: kind),
            scope: .selfReflection,
            scopeRefId: nil,
            status: .pending,
            authority: .tentative,
            confidence: confidence,
            eventTime: now,
            createdAt: now,
            updatedAt: now,
            sourceNodeId: sourceNodeId,
            sourceMessageId: sourceMessageId
        )
    }

    private func patternObservations(for kind: InTurnPatternKind) throws -> [MemoryObservation] {
        let key = Self.observationKey(for: kind)
        return try nodeStore.fetchMemoryObservations()
            .filter { observation in
                observation.extractedType == .pattern
                    && MemoryGraphAtomMapper.normalizedLine(observation.rawText) == MemoryGraphAtomMapper.normalizedLine(key)
                    && observation.confidence >= highConfidenceThreshold
                    && observation.sourceMessageId != nil
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func matchingPatternAtom(
        for kind: InTurnPatternKind,
        statuses: Set<MemoryStatus>
    ) throws -> MemoryAtom? {
        let key = Self.observationKey(for: kind)
        return try nodeStore.fetchMemoryAtoms(
            types: [.pattern],
            statuses: statuses,
            scope: .selfReflection,
            scopeRefId: nil,
            eventTimeStart: nil,
            eventTimeEnd: nil,
            limit: nil
        )
        .first { atom in
            MemoryGraphAtomMapper.normalizedLine(atom.normalizedKey ?? "")
                == MemoryGraphAtomMapper.normalizedLine(key)
        }
    }

    private func projectMatches(_ sourceNodeId: UUID?, projectId: UUID?) -> Bool {
        guard let sourceNodeId,
              let node = try? nodeStore.fetchNode(id: sourceNodeId)
        else {
            return projectId == nil
        }
        return node.projectId == projectId
    }

    static func observationKey(for kind: InTurnPatternKind) -> String {
        MemoryGraphWriter.normalizedKey(
            type: .pattern,
            statement: "in_turn_pattern:\(kind.rawValue)"
        )
    }

    static func proposalStatement(for kind: InTurnPatternKind) -> String {
        "Alex may repeatedly show \(kind.displayLabel). Evidence comes from repeated in-turn pattern signals. Suggested action: \(kind.pairedAction)."
    }

    private static func uniqueMessageEvidence(from observations: [MemoryObservation]) -> [MemoryObservation] {
        var seen = Set<UUID>()
        return observations.filter { observation in
            guard let messageId = observation.sourceMessageId else { return false }
            if seen.contains(messageId) { return false }
            seen.insert(messageId)
            return true
        }
    }

    private static func timeSpan(for observations: [MemoryObservation]) -> TimeInterval {
        guard let first = observations.first?.createdAt,
              let last = observations.last?.createdAt
        else {
            return 0
        }
        return max(0, last.timeIntervalSince(first))
    }

    private static func daySpan(for observations: [MemoryObservation]) -> Double {
        timeSpan(for: observations) / 86_400
    }

    private static func averageConfidence(for observations: [MemoryObservation]) -> Double {
        guard !observations.isEmpty else { return 0 }
        return observations.reduce(0) { $0 + $1.confidence } / Double(observations.count)
    }

    private static let supportedKinds: [InTurnPatternKind] = [
        .comparisonLoop,
        .identityPressure,
        .planningAsAvoidance,
        .learningInsteadOfShipping,
        .externalJudgmentSensitivity,
        .notReadyRationalization,
        .bigSystemEscape,
        .overTrustingSystem
    ]
}
