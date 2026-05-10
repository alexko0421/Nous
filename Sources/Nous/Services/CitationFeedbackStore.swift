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
}
