import Foundation

struct CitationFeedbackRow: Equatable {
    let conversationId: UUID
    let turnId: UUID
    let atomId: UUID
    let verdict: ThumbVerdict
    let note: String?
    let verdictAt: Date
}

/// Phase A chat citation feedback. Per-turn immutable identity
/// `(conversationId, turnId, atomId)` keyed; multiple thumbs on the same
/// row overwrite (no verdict_count — chat citations are a one-shot
/// per-turn surface, a count would be misleading).
final class CitationFeedbackStore {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func upsert(
        conversationId: UUID,
        turnId: UUID,
        atomId: UUID,
        verdict: ThumbVerdict,
        note: String?
    ) throws {
        let now = Date().timeIntervalSince1970
        let stmt = try nodeStore.rawDatabase.prepare("""
            INSERT INTO citation_feedback
              (conversation_id, turn_id, atom_id, verdict, note, verdict_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(conversation_id, turn_id, atom_id) DO UPDATE SET
                verdict = excluded.verdict,
                note = excluded.note,
                verdict_at = excluded.verdict_at;
        """)
        try stmt.bind(conversationId.uuidString, at: 1)
        try stmt.bind(turnId.uuidString, at: 2)
        try stmt.bind(atomId.uuidString, at: 3)
        try stmt.bind(verdict.rawValue, at: 4)
        try stmt.bind(note, at: 5)
        try stmt.bind(now, at: 6)
        try stmt.step()
    }

    func fetch(
        conversationId: UUID,
        turnId: UUID,
        atomId: UUID
    ) throws -> CitationFeedbackRow? {
        let stmt = try nodeStore.rawDatabase.prepare("""
            SELECT conversation_id, turn_id, atom_id, verdict, note, verdict_at
            FROM citation_feedback
            WHERE conversation_id = ? AND turn_id = ? AND atom_id = ?;
        """)
        try stmt.bind(conversationId.uuidString, at: 1)
        try stmt.bind(turnId.uuidString, at: 2)
        try stmt.bind(atomId.uuidString, at: 3)
        guard try stmt.step() else { return nil }
        return CitationFeedbackRow(
            conversationId: UUID(uuidString: stmt.text(at: 0) ?? "") ?? conversationId,
            turnId: UUID(uuidString: stmt.text(at: 1) ?? "") ?? turnId,
            atomId: UUID(uuidString: stmt.text(at: 2) ?? "") ?? atomId,
            verdict: ThumbVerdict(rawValue: stmt.text(at: 3) ?? "") ?? .unset,
            note: stmt.text(at: 4),
            verdictAt: Date(timeIntervalSince1970: stmt.double(at: 5))
        )
    }

    /// Aggregate per-entry feedback penalty across all conversations + turns.
    /// Mirrors the judge feedback loop (`TurnPlanner.buildJudgeFeedbackLoop`):
    /// down = +2.0, up = −1.0, decayed by `pow(0.82, ageHours/24)` (~3.5-day
    /// half-life) so a thumbs-down from this morning weighs heavily but a
    /// month-old one fades. Atom feedback is intentionally global — a bad
    /// atom is bad everywhere, not just in the chat where it was thumbed.
    ///
    /// Returns only entries with non-zero penalty; absent keys mean neutral.
    func fetchAggregatedPenalty(
        entryIds: [UUID],
        now: Date = Date()
    ) throws -> [UUID: Double] {
        guard !entryIds.isEmpty else { return [:] }
        let placeholders = entryIds.map { _ in "?" }.joined(separator: ",")
        let stmt = try nodeStore.rawDatabase.prepare("""
            SELECT atom_id, verdict, verdict_at
            FROM citation_feedback
            WHERE atom_id IN (\(placeholders));
        """)
        for (index, id) in entryIds.enumerated() {
            try stmt.bind(id.uuidString, at: Int32(index + 1))
        }
        var penalty: [UUID: Double] = [:]
        while try stmt.step() {
            guard let atomIdString = stmt.text(at: 0),
                  let atomId = UUID(uuidString: atomIdString),
                  let verdictRaw = stmt.text(at: 1),
                  let verdict = ThumbVerdict(rawValue: verdictRaw)
            else { continue }
            let verdictAt = Date(timeIntervalSince1970: stmt.double(at: 2))
            let ageHours = max(0, now.timeIntervalSince(verdictAt) / 3600.0)
            let decay = pow(0.82, ageHours / 24.0)
            let weight: Double
            switch verdict {
            case .down: weight = 2.0 * decay
            case .up: weight = -1.0 * decay
            case .unset: continue
            }
            penalty[atomId, default: 0] += weight
        }
        return penalty
    }
}
