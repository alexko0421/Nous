import Foundation

protocol ShadowLearningStoring {
    func fetchPatterns(userId: String) throws -> [ShadowLearningPattern]
    func fetchPattern(userId: String, kind: ShadowPatternKind, label: String) throws -> ShadowLearningPattern?
    func fetchPromptEligiblePatterns(userId: String, now: Date, limit: Int) throws -> [ShadowLearningPattern]
    func fetchRecentUserMessages(since: Date?, afterMessageId: UUID?, limit: Int) throws -> [Message]
    func upsertPattern(_ pattern: ShadowLearningPattern) throws
    func appendEvent(_ event: LearningEvent) throws
    func hasEvent(userId: String, patternId: UUID, sourceMessageId: UUID, eventType: LearningEventType) throws -> Bool
    func fetchRecentEvents(userId: String, limit: Int) throws -> [LearningEvent]
    func fetchState(userId: String) throws -> ShadowLearningState
    func saveState(_ state: ShadowLearningState) throws
}

final class ShadowLearningStore: ShadowLearningStoring {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func fetchPatterns(userId: String) throws -> [ShadowLearningPattern] {
        let stmt = try database.prepare("""
            SELECT \(Self.patternColumns)
            FROM shadow_patterns
            WHERE user_id = ?
            ORDER BY weight DESC, confidence DESC, last_seen_at DESC;
        """)
        try stmt.bind(userId, at: 1)

        var patterns: [ShadowLearningPattern] = []
        while try stmt.step() {
            if let pattern = pattern(from: stmt) {
                patterns.append(pattern)
            }
        }
        return patterns
    }

    func fetchPattern(userId: String, kind: ShadowPatternKind, label: String) throws -> ShadowLearningPattern? {
        let stmt = try database.prepare("""
            SELECT \(Self.patternColumns)
            FROM shadow_patterns
            WHERE user_id = ? AND kind = ? AND label = ?
            LIMIT 1;
        """)
        try stmt.bind(userId, at: 1)
        try stmt.bind(kind.rawValue, at: 2)
        try stmt.bind(label, at: 3)

        guard try stmt.step() else { return nil }
        return pattern(from: stmt)
    }

    func fetchPromptEligiblePatterns(userId: String, now: Date, limit: Int) throws -> [ShadowLearningPattern] {
        guard limit > 0 else { return [] }

        let stmt = try database.prepare("""
            SELECT \(Self.patternColumns)
            FROM shadow_patterns
            WHERE user_id = ?
              AND status IN ('soft', 'strong')
              AND confidence >= 0.65
              AND weight >= 0.25
            ORDER BY weight DESC, confidence DESC, last_seen_at DESC;
        """)
        try stmt.bind(userId, at: 1)

        var patterns: [ShadowLearningPattern] = []
        while patterns.count < limit, try stmt.step() {
            guard let pattern = pattern(from: stmt) else {
                continue
            }
            if ShadowPatternLifecycle.isPromptEligible(pattern, now: now) {
                patterns.append(pattern)
            }
        }
        return patterns
    }

    func fetchRecentUserMessages(since: Date?, afterMessageId: UUID?, limit: Int) throws -> [Message] {
        guard limit > 0 else { return [] }

        let stmt: Statement
        if let since, let afterMessageId {
            stmt = try database.prepare("""
                SELECT id, nodeId, role, content, timestamp, thinking_content, agent_trace_json, source
                FROM messages
                WHERE role = 'user'
                  AND (timestamp > ? OR (timestamp = ? AND id > ?))
                ORDER BY timestamp ASC, id ASC
                LIMIT ?;
            """)
            try stmt.bind(since.timeIntervalSince1970, at: 1)
            try stmt.bind(since.timeIntervalSince1970, at: 2)
            try stmt.bind(afterMessageId.uuidString, at: 3)
            try stmt.bind(limit, at: 4)
        } else if let since {
            stmt = try database.prepare("""
                SELECT id, nodeId, role, content, timestamp, thinking_content, agent_trace_json, source
                FROM messages
                WHERE role = 'user' AND timestamp > ?
                ORDER BY timestamp ASC, id ASC
                LIMIT ?;
            """)
            try stmt.bind(since.timeIntervalSince1970, at: 1)
            try stmt.bind(limit, at: 2)
        } else {
            stmt = try database.prepare("""
                SELECT id, nodeId, role, content, timestamp, thinking_content, agent_trace_json, source
                FROM messages
                WHERE role = 'user'
                ORDER BY timestamp ASC, id ASC
                LIMIT ?;
            """)
            try stmt.bind(limit, at: 1)
        }

        var messages: [Message] = []
        while try stmt.step() {
            guard let message = message(from: stmt) else {
                continue
            }
            messages.append(message)
        }
        return messages
    }

    func upsertPattern(_ pattern: ShadowLearningPattern) throws {
        let evidenceJSON = try encodedEvidenceMessageIds(pattern.evidenceMessageIds)

        try nodeStore.inTransaction {
            let stmt = try database.prepare("""
                INSERT INTO shadow_patterns (
                    id, user_id, kind, label, summary, prompt_fragment,
                    trigger_hint, confidence, weight, status, evidence_message_ids,
                    first_seen_at, last_seen_at, last_reinforced_at,
                    last_corrected_at, active_from, active_until
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id, kind, label) DO UPDATE SET
                    summary = excluded.summary,
                    prompt_fragment = excluded.prompt_fragment,
                    trigger_hint = excluded.trigger_hint,
                    confidence = excluded.confidence,
                    weight = excluded.weight,
                    status = excluded.status,
                    evidence_message_ids = excluded.evidence_message_ids,
                    last_seen_at = excluded.last_seen_at,
                    last_reinforced_at = excluded.last_reinforced_at,
                    last_corrected_at = excluded.last_corrected_at,
                    active_from = excluded.active_from,
                    active_until = excluded.active_until;
            """)
            try bind(pattern, evidenceJSON: evidenceJSON, to: stmt)
            try stmt.step()
        }
    }

    func appendEvent(_ event: LearningEvent) throws {
        try nodeStore.inTransaction {
            let stmt = try database.prepare("""
                INSERT INTO learning_events (
                    id, user_id, pattern_id, source_message_id,
                    event_type, note, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
            try stmt.bind(event.id.uuidString, at: 1)
            try stmt.bind(event.userId, at: 2)
            try stmt.bind(event.patternId?.uuidString, at: 3)
            try stmt.bind(event.sourceMessageId?.uuidString, at: 4)
            try stmt.bind(event.eventType.rawValue, at: 5)
            try stmt.bind(event.note, at: 6)
            try stmt.bind(event.createdAt.timeIntervalSince1970, at: 7)
            try stmt.step()
        }
    }

    func hasEvent(
        userId: String,
        patternId: UUID,
        sourceMessageId: UUID,
        eventType: LearningEventType
    ) throws -> Bool {
        let stmt = try database.prepare("""
            SELECT 1
            FROM learning_events
            WHERE user_id = ?
              AND pattern_id = ?
              AND source_message_id = ?
              AND event_type = ?
            LIMIT 1;
        """)
        try stmt.bind(userId, at: 1)
        try stmt.bind(patternId.uuidString, at: 2)
        try stmt.bind(sourceMessageId.uuidString, at: 3)
        try stmt.bind(eventType.rawValue, at: 4)
        return try stmt.step()
    }

    func fetchRecentEvents(userId: String, limit: Int) throws -> [LearningEvent] {
        guard limit > 0 else { return [] }

        let stmt = try database.prepare("""
            SELECT id, user_id, pattern_id, source_message_id, event_type, note, created_at
            FROM learning_events
            WHERE user_id = ?
            ORDER BY created_at DESC
            LIMIT ?;
        """)
        try stmt.bind(userId, at: 1)
        try stmt.bind(limit, at: 2)

        var events: [LearningEvent] = []
        while try stmt.step() {
            if let event = event(from: stmt) {
                events.append(event)
            }
        }
        return events
    }

    func fetchState(userId: String) throws -> ShadowLearningState {
        let stmt = try database.prepare("""
            SELECT user_id, last_run_at, last_scanned_message_at, last_scanned_message_id, last_consolidated_at
            FROM shadow_learning_state
            WHERE user_id = ?
            LIMIT 1;
        """)
        try stmt.bind(userId, at: 1)

        guard try stmt.step() else {
            return ShadowLearningState(
                userId: userId,
                lastRunAt: nil,
                lastScannedMessageAt: nil,
                lastScannedMessageId: nil,
                lastConsolidatedAt: nil
            )
        }

        return ShadowLearningState(
            userId: stmt.text(at: 0) ?? userId,
            lastRunAt: optionalDate(from: stmt, at: 1),
            lastScannedMessageAt: optionalDate(from: stmt, at: 2),
            lastScannedMessageId: optionalUUID(from: stmt, at: 3),
            lastConsolidatedAt: optionalDate(from: stmt, at: 4)
        )
    }

    func saveState(_ state: ShadowLearningState) throws {
        try nodeStore.inTransaction {
            let stmt = try database.prepare("""
                INSERT INTO shadow_learning_state (
                    user_id, last_run_at, last_scanned_message_at,
                    last_scanned_message_id, last_consolidated_at
                )
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                    last_run_at = excluded.last_run_at,
                    last_scanned_message_at = excluded.last_scanned_message_at,
                    last_scanned_message_id = excluded.last_scanned_message_id,
                    last_consolidated_at = excluded.last_consolidated_at;
            """)
            try stmt.bind(state.userId, at: 1)
            try stmt.bind(state.lastRunAt?.timeIntervalSince1970, at: 2)
            try stmt.bind(state.lastScannedMessageAt?.timeIntervalSince1970, at: 3)
            try stmt.bind(state.lastScannedMessageId?.uuidString, at: 4)
            try stmt.bind(state.lastConsolidatedAt?.timeIntervalSince1970, at: 5)
            try stmt.step()
        }
    }

    private static let patternColumns = """
        id, user_id, kind, label, summary, prompt_fragment, trigger_hint,
        confidence, weight, status, evidence_message_ids, first_seen_at,
        last_seen_at, last_reinforced_at, last_corrected_at, active_from,
        active_until
        """

    private var database: Database {
        nodeStore.rawDatabase
    }

    private func bind(_ pattern: ShadowLearningPattern, evidenceJSON: String, to stmt: Statement) throws {
        try stmt.bind(pattern.id.uuidString, at: 1)
        try stmt.bind(pattern.userId, at: 2)
        try stmt.bind(pattern.kind.rawValue, at: 3)
        try stmt.bind(pattern.label, at: 4)
        try stmt.bind(pattern.summary, at: 5)
        try stmt.bind(pattern.promptFragment, at: 6)
        try stmt.bind(pattern.triggerHint, at: 7)
        try stmt.bind(pattern.confidence, at: 8)
        try stmt.bind(pattern.weight, at: 9)
        try stmt.bind(pattern.status.rawValue, at: 10)
        try stmt.bind(evidenceJSON, at: 11)
        try stmt.bind(pattern.firstSeenAt.timeIntervalSince1970, at: 12)
        try stmt.bind(pattern.lastSeenAt.timeIntervalSince1970, at: 13)
        try stmt.bind(pattern.lastReinforcedAt?.timeIntervalSince1970, at: 14)
        try stmt.bind(pattern.lastCorrectedAt?.timeIntervalSince1970, at: 15)
        try stmt.bind(pattern.activeFrom?.timeIntervalSince1970, at: 16)
        try stmt.bind(pattern.activeUntil?.timeIntervalSince1970, at: 17)
    }

    private func pattern(from stmt: Statement) -> ShadowLearningPattern? {
        guard let idString = stmt.text(at: 0),
              let id = UUID(uuidString: idString) else {
            print("[ShadowLearningStore] skipping row with invalid pattern id")
            return nil
        }
        guard let kindRaw = stmt.text(at: 2),
              let kind = ShadowPatternKind(rawValue: kindRaw) else {
            print("[ShadowLearningStore] skipping pattern \(id) with invalid kind")
            return nil
        }
        guard let statusRaw = stmt.text(at: 9),
              let status = ShadowPatternStatus(rawValue: statusRaw) else {
            print("[ShadowLearningStore] skipping pattern \(id) with invalid status")
            return nil
        }
        guard let evidenceJSON = stmt.text(at: 10),
              let evidenceMessageIds = decodedEvidenceMessageIds(evidenceJSON) else {
            print("[ShadowLearningStore] skipping pattern \(id) with invalid evidence ids")
            return nil
        }

        return ShadowLearningPattern(
            id: id,
            userId: stmt.text(at: 1) ?? "alex",
            kind: kind,
            label: stmt.text(at: 3) ?? "",
            summary: stmt.text(at: 4) ?? "",
            promptFragment: stmt.text(at: 5) ?? "",
            triggerHint: stmt.text(at: 6) ?? "",
            confidence: stmt.double(at: 7),
            weight: stmt.double(at: 8),
            status: status,
            evidenceMessageIds: evidenceMessageIds,
            firstSeenAt: Date(timeIntervalSince1970: stmt.double(at: 11)),
            lastSeenAt: Date(timeIntervalSince1970: stmt.double(at: 12)),
            lastReinforcedAt: optionalDate(from: stmt, at: 13),
            lastCorrectedAt: optionalDate(from: stmt, at: 14),
            activeFrom: optionalDate(from: stmt, at: 15),
            activeUntil: optionalDate(from: stmt, at: 16)
        )
    }

    private func message(from stmt: Statement) -> Message? {
        guard let idString = stmt.text(at: 0),
              let id = UUID(uuidString: idString),
              let nodeIdString = stmt.text(at: 1),
              let nodeId = UUID(uuidString: nodeIdString),
              let roleRaw = stmt.text(at: 2),
              let role = MessageRole(rawValue: roleRaw) else {
            print("[ShadowLearningStore] skipping row with invalid message fields")
            return nil
        }

        return Message(
            id: id,
            nodeId: nodeId,
            role: role,
            content: stmt.text(at: 3) ?? "",
            timestamp: Date(timeIntervalSince1970: stmt.double(at: 4)),
            thinkingContent: stmt.text(at: 5),
            agentTraceJson: stmt.text(at: 6),
            source: MessageSource(rawValue: stmt.text(at: 7) ?? "") ?? .typed
        )
    }

    private func event(from stmt: Statement) -> LearningEvent? {
        guard let idString = stmt.text(at: 0),
              let id = UUID(uuidString: idString) else {
            print("[ShadowLearningStore] skipping row with invalid event id")
            return nil
        }
        guard let eventTypeRaw = stmt.text(at: 4),
              let eventType = LearningEventType(rawValue: eventTypeRaw) else {
            print("[ShadowLearningStore] skipping event \(id) with invalid type")
            return nil
        }

        let patternId: UUID?
        if let patternIdString = stmt.text(at: 2) {
            guard let uuid = UUID(uuidString: patternIdString) else {
                print("[ShadowLearningStore] skipping event \(id) with invalid pattern id")
                return nil
            }
            patternId = uuid
        } else {
            patternId = nil
        }

        let sourceMessageId: UUID?
        if let sourceMessageIdString = stmt.text(at: 3) {
            guard let uuid = UUID(uuidString: sourceMessageIdString) else {
                print("[ShadowLearningStore] skipping event \(id) with invalid source message id")
                return nil
            }
            sourceMessageId = uuid
        } else {
            sourceMessageId = nil
        }

        return LearningEvent(
            id: id,
            userId: stmt.text(at: 1) ?? "alex",
            patternId: patternId,
            sourceMessageId: sourceMessageId,
            eventType: eventType,
            note: stmt.text(at: 5) ?? "",
            createdAt: Date(timeIntervalSince1970: stmt.double(at: 6))
        )
    }

    private func encodedEvidenceMessageIds(_ ids: [UUID]) throws -> String {
        let data = try JSONEncoder().encode(ids.map(\.uuidString))
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decodedEvidenceMessageIds(_ json: String) -> [UUID]? {
        guard let data = json.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }

        var ids: [UUID] = []
        for string in strings {
            guard let id = UUID(uuidString: string) else {
                return nil
            }
            ids.append(id)
        }
        return ids
    }

    private func optionalDate(from stmt: Statement, at column: Int32) -> Date? {
        guard !stmt.isNull(at: column) else { return nil }
        return Date(timeIntervalSince1970: stmt.double(at: column))
    }

    private func optionalUUID(from stmt: Statement, at column: Int32) -> UUID? {
        guard let raw = stmt.text(at: column) else { return nil }
        return UUID(uuidString: raw)
    }
}
