import Foundation

struct CitationJudgeTraceRow: Equatable {
    let id: Int
    let conversationId: UUID
    let turnId: UUID
    let atomId: UUID
    let confidence: Double
    let wasDisplayed: Bool
    let judgedAt: Date
}

/// Phase A chat citation telemetry. Append-only — one row per candidate
/// atom per turn, including those filtered by the UI confidence floor.
/// Capturing both shown AND filtered atoms lets Phase A2 study the
/// cascade decision, not just what made it to the chip bar.
final class CitationJudgeTraceStore {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func append(
        conversationId: UUID,
        turnId: UUID,
        atomId: UUID,
        confidence: Double,
        wasDisplayed: Bool
    ) throws {
        let now = Date().timeIntervalSince1970
        let stmt = try nodeStore.rawDatabase.prepare("""
            INSERT INTO citation_judge_trace
              (conversation_id, turn_id, atom_id, confidence, was_displayed, judged_at)
            VALUES (?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(conversationId.uuidString, at: 1)
        try stmt.bind(turnId.uuidString, at: 2)
        try stmt.bind(atomId.uuidString, at: 3)
        try stmt.bind(confidence, at: 4)
        try stmt.bind(wasDisplayed ? 1 : 0, at: 5)
        try stmt.bind(now, at: 6)
        try stmt.step()
    }

    func byTurn(turnId: UUID) throws -> [CitationJudgeTraceRow] {
        let stmt = try nodeStore.rawDatabase.prepare("""
            SELECT id, conversation_id, turn_id, atom_id, confidence, was_displayed, judged_at
            FROM citation_judge_trace
            WHERE turn_id = ?
            ORDER BY judged_at ASC;
        """)
        try stmt.bind(turnId.uuidString, at: 1)
        var rows: [CitationJudgeTraceRow] = []
        while try stmt.step() {
            let convString = stmt.text(at: 1) ?? ""
            let turnString = stmt.text(at: 2) ?? turnId.uuidString
            let atomString = stmt.text(at: 3) ?? ""
            rows.append(CitationJudgeTraceRow(
                id: stmt.int(at: 0),
                conversationId: UUID(uuidString: convString) ?? UUID(),
                turnId: UUID(uuidString: turnString) ?? turnId,
                atomId: UUID(uuidString: atomString) ?? UUID(),
                confidence: stmt.double(at: 4),
                wasDisplayed: stmt.int(at: 5) == 1,
                judgedAt: Date(timeIntervalSince1970: stmt.double(at: 6))
            ))
        }
        return rows
    }
}
