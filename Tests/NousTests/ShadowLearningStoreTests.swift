import XCTest
@testable import Nous

final class ShadowLearningStoreTests: XCTestCase {

    private var nodeStore: NodeStore!
    private var store: ShadowLearningStore!

    override func setUp() {
        super.setUp()
        nodeStore = try! NodeStore(path: ":memory:")
        store = ShadowLearningStore(nodeStore: nodeStore)
    }

    override func tearDown() {
        store = nil
        nodeStore = nil
        super.tearDown()
    }

    func testInsertFetchUpdatePatternRoundTrip() throws {
        let evidence = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        ]
        let original = makePattern(
            label: "first_principles",
            confidence: 0.66,
            weight: 0.31,
            status: .soft,
            evidenceMessageIds: evidence,
            lastReinforcedAt: Date(timeIntervalSince1970: 1_300),
            activeFrom: Date(timeIntervalSince1970: 1_250)
        )

        try store.upsertPattern(original)

        XCTAssertEqual(try store.fetchPattern(userId: "alex", kind: .thinkingMove, label: "first_principles"), original)
        XCTAssertEqual(try store.fetchPatterns(userId: "alex"), [original])

        var updated = original
        updated.summary = "Alex prefers stripping product choices down to base constraints."
        updated.promptFragment = "Start from the base constraint before analogy."
        updated.triggerHint = "product or architecture choice"
        updated.confidence = 0.84
        updated.weight = 0.58
        updated.status = .strong
        updated.evidenceMessageIds.append(UUID(uuidString: "00000000-0000-0000-0000-000000000103")!)
        updated.lastSeenAt = Date(timeIntervalSince1970: 1_600)
        updated.lastCorrectedAt = Date(timeIntervalSince1970: 1_500)
        updated.activeUntil = Date(timeIntervalSince1970: 2_000)

        try store.upsertPattern(updated)

        XCTAssertEqual(try store.fetchPattern(userId: "alex", kind: .thinkingMove, label: "first_principles"), updated)
    }

    func testAppendAndFetchRecentLearningEvents() throws {
        let pattern = makePattern()
        try store.upsertPattern(pattern)
        let oldEvent = makeEvent(
            patternId: pattern.id,
            eventType: .observed,
            note: "First mention",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        let recentEvent = makeEvent(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            patternId: pattern.id,
            eventType: .reinforced,
            note: "User corrected toward this frame again",
            createdAt: Date(timeIntervalSince1970: 2_100)
        )

        try store.appendEvent(oldEvent)
        try store.appendEvent(recentEvent)

        XCTAssertEqual(try store.fetchRecentEvents(userId: "alex", limit: 1), [recentEvent])
        XCTAssertEqual(try store.fetchRecentEvents(userId: "alex", limit: 10), [recentEvent, oldEvent])
    }

    func testHasEventMatchesUserPatternSourceAndType() throws {
        let pattern = makePattern()
        try store.upsertPattern(pattern)
        let sourceMessageId = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
        try insertMessage(id: sourceMessageId, nodeId: UUID(uuidString: "00000000-0000-0000-0000-000000000502")!)
        let event = makeEvent(
            patternId: pattern.id,
            sourceMessageId: sourceMessageId,
            eventType: .corrected,
            note: "Correction",
            createdAt: Date(timeIntervalSince1970: 2_200)
        )

        try store.appendEvent(event)

        XCTAssertTrue(try store.hasEvent(
            userId: "alex",
            patternId: pattern.id,
            sourceMessageId: sourceMessageId,
            eventType: .corrected
        ))
        XCTAssertFalse(try store.hasEvent(
            userId: "alex",
            patternId: pattern.id,
            sourceMessageId: sourceMessageId,
            eventType: .observed
        ))
    }

    func testLearningStateRoundTrip() throws {
        XCTAssertEqual(
            try store.fetchState(userId: "alex"),
            ShadowLearningState(
                userId: "alex",
                lastRunAt: nil,
                lastScannedMessageAt: nil,
                lastScannedMessageId: nil,
                lastConsolidatedAt: nil
            )
        )

        let lastScannedMessageId = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
        let state = ShadowLearningState(
            userId: "alex",
            lastRunAt: Date(timeIntervalSince1970: 3_000),
            lastScannedMessageAt: Date(timeIntervalSince1970: 3_100),
            lastScannedMessageId: lastScannedMessageId,
            lastConsolidatedAt: Date(timeIntervalSince1970: 3_200)
        )

        try store.saveState(state)

        XCTAssertEqual(try store.fetchState(userId: "alex"), state)
    }

    func testFetchRecentUserMessagesUsesCompoundCursorForSameTimestampPages() throws {
        let node = NousNode(type: .conversation, title: "Cursor")
        try nodeStore.insertNode(node)
        let timestamp = Date(timeIntervalSince1970: 4_000)
        let ids = (0..<202).map { index in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 700 + index))!
        }
        for (index, id) in ids.enumerated() {
            try nodeStore.insertMessage(Message(
                id: id,
                nodeId: node.id,
                role: .user,
                content: "Message \(index)",
                timestamp: timestamp
            ))
        }

        let messages = try store.fetchRecentUserMessages(
            since: timestamp,
            afterMessageId: ids[199],
            limit: 10
        )

        XCTAssertEqual(messages.map(\.id), Array(ids[200...201]))
    }

    func testPromptEligibleFiltersRetiredAndRecentlyCorrectedPatterns() throws {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let eligible = makePattern(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
            label: "pain_test",
            confidence: 0.80,
            weight: 0.50,
            status: .soft,
            lastSeenAt: now.addingTimeInterval(-100)
        )
        let retired = makePattern(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000011")!,
            label: "old_frame",
            confidence: 0.95,
            weight: 0.95,
            status: .retired,
            lastSeenAt: now.addingTimeInterval(-50)
        )
        let recentlyCorrected = makePattern(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000012")!,
            label: "too_hard_pushback",
            confidence: 0.90,
            weight: 0.90,
            status: .strong,
            lastSeenAt: now.addingTimeInterval(-25),
            lastCorrectedAt: now.addingTimeInterval(-2 * 86_400)
        )

        try store.upsertPattern(retired)
        try store.upsertPattern(recentlyCorrected)
        try store.upsertPattern(eligible)

        XCTAssertEqual(try store.fetchPromptEligiblePatterns(userId: "alex", now: now, limit: 10), [eligible])
    }

    func testUpsertSameUserKindLabelPreservesOriginalIdentityAndFirstSeenAt() throws {
        let original = makePattern(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000020")!,
            label: "concrete_over_generic",
            confidence: 0.61,
            weight: 0.20,
            status: .observed,
            evidenceMessageIds: [UUID(uuidString: "00000000-0000-0000-0000-000000000301")!],
            firstSeenAt: Date(timeIntervalSince1970: 4_000),
            lastSeenAt: Date(timeIntervalSince1970: 4_100)
        )
        let replacement = makePattern(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000021")!,
            label: "concrete_over_generic",
            confidence: 0.72,
            weight: 0.37,
            status: .soft,
            evidenceMessageIds: [
                UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
            ],
            firstSeenAt: Date(timeIntervalSince1970: 9_000),
            lastSeenAt: Date(timeIntervalSince1970: 4_500)
        )

        try store.upsertPattern(original)
        try store.upsertPattern(replacement)

        let fetched = try XCTUnwrap(store.fetchPattern(userId: "alex", kind: .thinkingMove, label: "concrete_over_generic"))
        XCTAssertEqual(fetched.id, original.id)
        XCTAssertEqual(fetched.firstSeenAt, original.firstSeenAt)
        XCTAssertEqual(fetched.weight, replacement.weight)
        XCTAssertEqual(fetched.status, replacement.status)
        XCTAssertEqual(fetched.evidenceMessageIds, replacement.evidenceMessageIds)
    }

    func testFetchPatternsSkipsRowsWithInvalidEvidenceUUIDs() throws {
        let valid = makePattern(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000030")!,
            label: "valid_evidence",
            confidence: 0.70,
            weight: 0.40,
            status: .soft,
            evidenceMessageIds: [UUID(uuidString: "00000000-0000-0000-0000-000000000401")!]
        )

        try store.upsertPattern(valid)
        try insertRawPattern(label: "bad_evidence", evidenceJSON: #"["not-a-uuid"]"#)

        XCTAssertEqual(try store.fetchPatterns(userId: "alex"), [valid])
    }

    private func makePattern(
        id: UUID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        userId: String = "alex",
        kind: ShadowPatternKind = .thinkingMove,
        label: String = "first_principles",
        summary: String = "Alex reaches for first principles in product decisions.",
        promptFragment: String = "Start from first principles before analogy.",
        triggerHint: String = "product or architecture judgment",
        confidence: Double = 0.70,
        weight: Double = 0.40,
        status: ShadowPatternStatus = .soft,
        evidenceMessageIds: [UUID] = [UUID(uuidString: "00000000-0000-0000-0000-000000000001")!],
        firstSeenAt: Date = Date(timeIntervalSince1970: 1_000),
        lastSeenAt: Date = Date(timeIntervalSince1970: 1_200),
        lastReinforcedAt: Date? = nil,
        lastCorrectedAt: Date? = nil,
        activeFrom: Date? = nil,
        activeUntil: Date? = nil
    ) -> ShadowLearningPattern {
        ShadowLearningPattern(
            id: id,
            userId: userId,
            kind: kind,
            label: label,
            summary: summary,
            promptFragment: promptFragment,
            triggerHint: triggerHint,
            confidence: confidence,
            weight: weight,
            status: status,
            evidenceMessageIds: evidenceMessageIds,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            lastReinforcedAt: lastReinforcedAt,
            lastCorrectedAt: lastCorrectedAt,
            activeFrom: activeFrom,
            activeUntil: activeUntil
        )
    }

    private func makeEvent(
        id: UUID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        userId: String = "alex",
        patternId: UUID? = nil,
        sourceMessageId: UUID? = nil,
        eventType: LearningEventType = .observed,
        note: String = "",
        createdAt: Date = Date(timeIntervalSince1970: 2_000)
    ) -> LearningEvent {
        LearningEvent(
            id: id,
            userId: userId,
            patternId: patternId,
            sourceMessageId: sourceMessageId,
            eventType: eventType,
            note: note,
            createdAt: createdAt
        )
    }

    private func insertRawPattern(label: String, evidenceJSON: String) throws {
        let stmt = try nodeStore.rawDatabase.prepare("""
            INSERT INTO shadow_patterns (
                id, user_id, kind, label, summary, prompt_fragment,
                trigger_hint, confidence, weight, status, evidence_message_ids,
                first_seen_at, last_seen_at
            )
            VALUES (?, 'alex', 'thinking_move', ?, 'Raw shadow pattern',
                    'Use the raw pattern.', 'test', 0.90, 0.90, 'soft', ?, 1000, 1200);
        """)
        try stmt.bind(UUID().uuidString, at: 1)
        try stmt.bind(label, at: 2)
        try stmt.bind(evidenceJSON, at: 3)
        try stmt.step()
    }

    private func insertMessage(id: UUID, nodeId: UUID) throws {
        try nodeStore.insertNode(NousNode(id: nodeId, type: .conversation, title: "Shadow store test"))
        try nodeStore.insertMessage(Message(id: id, nodeId: nodeId, role: .user, content: "Correction"))
    }
}
