import Foundation

struct EdgeFeedbackRow: Equatable {
    let nodeAId: UUID
    let nodeBId: UUID
    let relationKind: String
    let verdict: ThumbVerdict
    let note: String?
    let verdictAt: Date
    let verdictCount: Int
}

/// Phase A galaxy edge feedback. Upsert-by-(normalized pair, relationKind)
/// so user verdicts survive edge regen of the same kind. Different-kind
/// regen leaves prior verdicts intact as a historical signal — see
/// docs/superpowers/specs/2026-05-09-edge-inference-feedback-ledger-design.md.
final class EdgeFeedbackStore {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func upsert(
        sourceId: UUID,
        targetId: UUID,
        relationKind: String,
        verdict: ThumbVerdict,
        note: String?
    ) throws {
        let (a, b) = Self.normalize(sourceId, targetId)
        let now = Date().timeIntervalSince1970
        let stmt = try nodeStore.rawDatabase.prepare("""
            INSERT INTO edge_feedback
              (node_a_id, node_b_id, relation_kind, verdict, note, verdict_at, verdict_count)
            VALUES (?, ?, ?, ?, ?, ?, 1)
            ON CONFLICT(node_a_id, node_b_id, relation_kind) DO UPDATE SET
                verdict = excluded.verdict,
                note = excluded.note,
                verdict_at = excluded.verdict_at,
                verdict_count = verdict_count + 1;
        """)
        try stmt.bind(a.uuidString, at: 1)
        try stmt.bind(b.uuidString, at: 2)
        try stmt.bind(relationKind, at: 3)
        try stmt.bind(verdict.rawValue, at: 4)
        try stmt.bind(note, at: 5)
        try stmt.bind(now, at: 6)
        try stmt.step()
    }

    func fetch(sourceId: UUID, targetId: UUID, relationKind: String) throws -> EdgeFeedbackRow? {
        let (a, b) = Self.normalize(sourceId, targetId)
        let stmt = try nodeStore.rawDatabase.prepare("""
            SELECT node_a_id, node_b_id, relation_kind, verdict, note, verdict_at, verdict_count
            FROM edge_feedback
            WHERE node_a_id = ? AND node_b_id = ? AND relation_kind = ?;
        """)
        try stmt.bind(a.uuidString, at: 1)
        try stmt.bind(b.uuidString, at: 2)
        try stmt.bind(relationKind, at: 3)
        guard try stmt.step() else { return nil }
        return EdgeFeedbackRow(
            nodeAId: UUID(uuidString: stmt.text(at: 0) ?? "") ?? a,
            nodeBId: UUID(uuidString: stmt.text(at: 1) ?? "") ?? b,
            relationKind: stmt.text(at: 2) ?? relationKind,
            verdict: ThumbVerdict(rawValue: stmt.text(at: 3) ?? "") ?? .unset,
            note: stmt.text(at: 4),
            verdictAt: Date(timeIntervalSince1970: stmt.double(at: 5)),
            verdictCount: stmt.int(at: 6)
        )
    }

    /// Pair normalization keeps (A, B) and (B, A) collapsed onto the same
    /// row — galaxy edges are undirected for feedback purposes. Match the
    /// invariant in EdgeJudgeTraceStore so feedback and trace agree on
    /// node ordering.
    private static func normalize(_ x: UUID, _ y: UUID) -> (UUID, UUID) {
        x.uuidString < y.uuidString ? (x, y) : (y, x)
    }
}
