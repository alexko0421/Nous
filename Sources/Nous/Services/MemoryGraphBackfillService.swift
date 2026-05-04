import Foundation

struct MemoryGraphBackfillReport: Equatable {
    var scannedFacts = 0
    var groupedFacts = 0
    var insertedAtoms = 0
    var updatedAtoms = 0
    var unchangedAtoms = 0
    var skippedFacts = 0
}

final class MemoryGraphBackfillService {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    @discardableResult
    func runIfNeeded() throws -> MemoryGraphBackfillReport {
        var report = MemoryGraphBackfillReport()

        try nodeStore.inTransaction {
            let facts = try nodeStore.fetchMemoryFactEntries()
            report.scannedFacts = facts.count

            let groups = Dictionary(grouping: facts, by: Self.identityKey(for:))
            report.groupedFacts = groups.count

            let writer = MemoryGraphWriter(nodeStore: nodeStore)
            var atoms = try nodeStore.fetchMemoryAtoms()
            var writeResult = MemoryGraphWriteResult()

            for group in groups.values {
                guard var candidate = try candidateAtom(from: group) else {
                    report.skippedFacts += group.count
                    continue
                }

                candidate.sourceNodeId = try firstExistingSourceNodeId(from: group)
                _ = try writer.upsertAtom(candidate, atoms: &atoms, result: &writeResult)
            }

            report.insertedAtoms = writeResult.insertedAtoms
            report.updatedAtoms = writeResult.updatedAtoms
            report.unchangedAtoms = writeResult.unchangedAtoms
        }

        return report
    }

    private func candidateAtom(from facts: [MemoryFactEntry]) throws -> MemoryAtom? {
        let sorted = facts.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.updatedAt < $1.updatedAt
        }
        guard let latest = sorted.last else { return nil }

        let statement = latest.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { return nil }
        guard let type = MemoryGraphAtomMapper.atomType(for: latest.kind, content: statement) else {
            return nil
        }

        let createdAt = sorted.map(\.createdAt).min() ?? latest.createdAt
        let confidence = latest.confidence
        return MemoryAtom(
            type: type,
            statement: statement,
            normalizedKey: MemoryGraphAtomMapper.factNormalizedKey(kind: latest.kind, content: statement),
            scope: latest.scope,
            scopeRefId: latest.scopeRefId,
            status: latest.status,
            confidence: confidence,
            eventTime: latest.updatedAt,
            createdAt: createdAt,
            updatedAt: latest.updatedAt,
            lastSeenAt: latest.updatedAt,
            sourceNodeId: nil
        )
    }

    private func firstExistingSourceNodeId(from facts: [MemoryFactEntry]) throws -> UUID? {
        let sourceIds = facts
            .sorted { $0.updatedAt > $1.updatedAt }
            .flatMap(\.sourceNodeIds)

        var seen = Set<UUID>()
        for sourceId in sourceIds where !seen.contains(sourceId) {
            seen.insert(sourceId)
            if try nodeStore.fetchNode(id: sourceId) != nil {
                return sourceId
            }
        }
        return nil
    }

    private static func identityKey(for fact: MemoryFactEntry) -> String {
        [
            fact.scope.rawValue,
            fact.scopeRefId?.uuidString ?? "",
            fact.kind.rawValue,
            MemoryGraphAtomMapper.normalizedLine(fact.content)
        ].joined(separator: "|")
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
        merged.confidence = candidate.confidence
        merged.eventTime = candidate.eventTime ?? existing.eventTime
        merged.validFrom = existing.validFrom
        merged.validUntil = existing.validUntil
        merged.updatedAt = max(existing.updatedAt, candidate.updatedAt)
        merged.lastSeenAt = maxDate(existing.lastSeenAt, candidate.lastSeenAt)
        merged.sourceNodeId = candidate.sourceNodeId ?? existing.sourceNodeId
        merged.sourceMessageId = existing.sourceMessageId
        merged.embedding = existing.embedding
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
            || lhs.updatedAt != rhs.updatedAt
            || lhs.lastSeenAt != rhs.lastSeenAt
            || lhs.sourceNodeId != rhs.sourceNodeId
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
