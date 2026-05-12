import Foundation

struct EdgeJudgeTraceRow: Equatable {
    let id: Int
    let nodeAId: UUID
    let nodeBId: UUID
    let relationKind: String?
    let judgePath: JudgePath
    let similarity: Double
    let confidence: Double?
    let judgedAt: Date
}

/// Phase A galaxy judge telemetry. Append-only — every relation-judge
/// decision (atom hit, LLM verdict, fallback acceptance, rejection)
/// produces one row. NULL `relation_kind` distinguishes "judge said no
/// connection" from "judge wasn't asked", which is the primary signal
/// Phase A2 will mine.
final class EdgeJudgeTraceStore {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func append(
        sourceId: UUID,
        targetId: UUID,
        relationKind: String?,
        judgePath: JudgePath,
        similarity: Double,
        confidence: Double?
    ) throws {
        let (a, b) = Self.normalize(sourceId, targetId)
        let now = Date().timeIntervalSince1970
        let stmt = try nodeStore.rawDatabase.prepare("""
            INSERT INTO edge_judge_trace
              (node_a_id, node_b_id, relation_kind, judge_path, similarity, confidence, judged_at)
            VALUES (?, ?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(a.uuidString, at: 1)
        try stmt.bind(b.uuidString, at: 2)
        try stmt.bind(relationKind, at: 3)
        try stmt.bind(judgePath.rawValue, at: 4)
        try stmt.bind(similarity, at: 5)
        try stmt.bind(confidence, at: 6)
        try stmt.bind(now, at: 7)
        try stmt.step()
    }

    func history(sourceId: UUID, targetId: UUID, limit: Int) throws -> [EdgeJudgeTraceRow] {
        let (a, b) = Self.normalize(sourceId, targetId)
        let stmt = try nodeStore.rawDatabase.prepare("""
            SELECT id, node_a_id, node_b_id, relation_kind, judge_path, similarity, confidence, judged_at
            FROM edge_judge_trace
            WHERE node_a_id = ? AND node_b_id = ?
            ORDER BY judged_at DESC
            LIMIT ?;
        """)
        try stmt.bind(a.uuidString, at: 1)
        try stmt.bind(b.uuidString, at: 2)
        try stmt.bind(limit, at: 3)
        var rows: [EdgeJudgeTraceRow] = []
        while try stmt.step() {
            rows.append(EdgeJudgeTraceRow(
                id: stmt.int(at: 0),
                nodeAId: UUID(uuidString: stmt.text(at: 1) ?? "") ?? a,
                nodeBId: UUID(uuidString: stmt.text(at: 2) ?? "") ?? b,
                relationKind: stmt.text(at: 3),
                judgePath: JudgePath(rawValue: stmt.text(at: 4) ?? "") ?? .fallback,
                similarity: stmt.double(at: 5),
                confidence: stmt.isNull(at: 6) ? nil : stmt.double(at: 6),
                judgedAt: Date(timeIntervalSince1970: stmt.double(at: 7))
            ))
        }
        return rows
    }

    func latest(sourceId: UUID, targetId: UUID) throws -> EdgeJudgeTraceRow? {
        try history(sourceId: sourceId, targetId: targetId, limit: 1).first
    }

    private static func normalize(_ x: UUID, _ y: UUID) -> (UUID, UUID) {
        x.uuidString < y.uuidString ? (x, y) : (y, x)
    }
}
