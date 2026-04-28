import Foundation

enum MemoryGraphAtomMapper {
    static func atomType(for kind: MemoryKind, content: String) -> MemoryAtomType? {
        switch kind {
        case .identity:
            return .identity
        case .preference:
            return .preference
        case .constraint:
            return .constraint
        case .decision:
            return containsRejectionCue(content) ? .rejection : .decision
        case .boundary:
            return .boundary
        case .relationship:
            return .entity
        case .thread:
            return .insight
        case .temporaryContext:
            return .event
        }
    }

    static func factNormalizedKey(kind: MemoryKind, content: String) -> String {
        "\(kind.rawValue)|\(normalizedLine(content))"
    }

    static func atom(fromFact entry: MemoryFactEntry, now: Date) -> MemoryAtom? {
        let statement = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !statement.isEmpty else { return nil }
        guard let type = atomType(for: entry.kind, content: statement) else { return nil }

        return MemoryAtom(
            type: type,
            statement: statement,
            normalizedKey: factNormalizedKey(kind: entry.kind, content: statement),
            scope: entry.scope,
            scopeRefId: entry.scopeRefId,
            status: entry.status,
            confidence: entry.confidence,
            eventTime: entry.updatedAt,
            createdAt: entry.createdAt,
            updatedAt: now,
            lastSeenAt: now,
            sourceNodeId: entry.sourceNodeIds.first
        )
    }

    static func normalizedLine(_ content: String) -> String {
        content
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func containsRejectionCue(_ content: String) -> Bool {
        let normalized = content.lowercased()
        let cues = [
            "reject", "rejected", "rejection", "decided against",
            "ruled out", "not pursue", "not build",
            "否決", "否决", "否定", "推翻", "放棄", "放弃"
        ]
        return cues.contains { normalized.contains($0) }
    }
}
