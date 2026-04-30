import XCTest
@testable import Nous

final class ShadowLearningStewardTests: XCTestCase {
    func testDailyRunSkipsWhenBelowMessageThreshold() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let steward = ShadowLearningSteward(store: store, minNewMessages: 15)

        let result = await steward.runIfDue(
            userId: "alex",
            now: Date(timeIntervalSince1970: 10_000),
            force: false
        )

        XCTAssertEqual(result, .skippedInsufficientMessages(0))
    }

    func testDailyRunUpdatesStateAndCapsPatternUpdates() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let steward = ShadowLearningSteward(store: store, minNewMessages: 3, maxPatternUpdates: 2)
        let node = NousNode(type: .conversation, title: "Learning")
        try nodeStore.insertNode(node)
        try insertUserMessage(nodeStore, nodeId: node.id, text: "先用 first principles", offset: 1)
        try insertUserMessage(nodeStore, nodeId: node.id, text: "这个太 generic 了", offset: 2)
        try insertUserMessage(nodeStore, nodeId: node.id, text: "用 pain test 看一下", offset: 3)

        let result = await steward.runIfDue(
            userId: "alex",
            now: Date(timeIntervalSince1970: 10_000),
            force: false
        )

        XCTAssertEqual(result, .updated(patternCount: 2))
        let patterns = try store.fetchPatterns(userId: "alex")
        XCTAssertEqual(patterns.count, 2)
        let state = try store.fetchState(userId: "alex")
        XCTAssertEqual(state.lastRunAt, Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(state.lastScannedMessageAt, Date(timeIntervalSince1970: 1_002))
        XCTAssertNotNil(state.lastScannedMessageId)
    }

    func testDailyRunCapsMultipleSignalsInOneMessage() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let steward = ShadowLearningSteward(store: store, minNewMessages: 1, maxPatternUpdates: 2)
        let node = NousNode(type: .conversation, title: "Multi-signal")
        try nodeStore.insertNode(node)
        try insertUserMessage(
            nodeStore,
            nodeId: node.id,
            text: "Use first principles, pain test, concrete tradeoffs, and push back",
            offset: 1
        )

        let result = await steward.runIfDue(
            userId: "alex",
            now: Date(timeIntervalSince1970: 10_000),
            force: false
        )

        XCTAssertEqual(result, .updated(patternCount: 2))
        XCTAssertEqual(try store.fetchPatterns(userId: "alex").count, 2)
        XCTAssertEqual(try store.fetchRecentEvents(userId: "alex", limit: 10).count, 2)
    }

    func testDailyRunCapsRepeatedWritesForSamePattern() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let steward = ShadowLearningSteward(store: store, minNewMessages: 1, maxPatternUpdates: 2)
        let node = NousNode(type: .conversation, title: "Repeated pattern")
        try nodeStore.insertNode(node)
        try insertUserMessage(
            nodeStore,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000004201")!,
            nodeId: node.id,
            text: "Use first principles",
            timestamp: Date(timeIntervalSince1970: 2_100)
        )
        try insertUserMessage(
            nodeStore,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000004202")!,
            nodeId: node.id,
            text: "Again, first principles",
            timestamp: Date(timeIntervalSince1970: 2_101)
        )
        try insertUserMessage(
            nodeStore,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000004203")!,
            nodeId: node.id,
            text: "One more first principles pass",
            timestamp: Date(timeIntervalSince1970: 2_102)
        )

        let result = await steward.runIfDue(
            userId: "alex",
            now: Date(timeIntervalSince1970: 10_000),
            force: false
        )

        XCTAssertEqual(result, .updated(patternCount: 2))
        let pattern = try XCTUnwrap(store.fetchPattern(
            userId: "alex",
            kind: .thinkingMove,
            label: "first_principles_decision_frame"
        ))
        XCTAssertEqual(pattern.evidenceMessageIds.count, 2)
        XCTAssertEqual(try store.fetchRecentEvents(userId: "alex", limit: 10).count, 2)
        let state = try store.fetchState(userId: "alex")
        XCTAssertEqual(state.lastScannedMessageId, UUID(uuidString: "00000000-0000-0000-0000-000000004202")!)
    }

    func testDailyRunDoesNotSkipSameTimestampMessagesWhenCapStopsEarly() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let steward = ShadowLearningSteward(store: store, minNewMessages: 1, maxPatternUpdates: 1)
        let node = NousNode(type: .conversation, title: "Same timestamp")
        let timestamp = Date(timeIntervalSince1970: 2_000)
        try nodeStore.insertNode(node)
        try insertUserMessage(
            nodeStore,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000004101")!,
            nodeId: node.id,
            text: "Use first principles",
            timestamp: timestamp
        )
        try insertUserMessage(
            nodeStore,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000004102")!,
            nodeId: node.id,
            text: "Use pain test",
            timestamp: timestamp
        )

        let firstRun = await steward.runIfDue(
            userId: "alex",
            now: Date(timeIntervalSince1970: 10_000),
            force: false
        )
        XCTAssertEqual(firstRun, .updated(patternCount: 1))
        XCTAssertEqual(try store.fetchPatterns(userId: "alex").count, 1)
        let firstState = try store.fetchState(userId: "alex")
        XCTAssertEqual(firstState.lastScannedMessageId, UUID(uuidString: "00000000-0000-0000-0000-000000004101")!)

        let secondRun = await steward.runIfDue(
            userId: "alex",
            now: Date(timeIntervalSince1970: 10_100),
            force: true
        )
        XCTAssertEqual(secondRun, .updated(patternCount: 1))
        XCTAssertEqual(try store.fetchPatterns(userId: "alex").count, 2)
        let secondState = try store.fetchState(userId: "alex")
        XCTAssertEqual(secondState.lastScannedMessageId, UUID(uuidString: "00000000-0000-0000-0000-000000004102")!)
    }

    func testWeeklyConsolidationDecaysStalePatterns() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        try store.upsertPattern(ShadowLearningPattern(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000004001")!,
            userId: "alex",
            kind: .thinkingMove,
            label: "pain_test_for_product_scope",
            summary: "Use pain test before adding scope.",
            promptFragment: "Ask whether absence would hurt before expanding scope.",
            triggerHint: "product scope pain test",
            confidence: 0.86,
            weight: 0.66,
            status: .strong,
            evidenceMessageIds: [],
            firstSeenAt: now.addingTimeInterval(-80 * 86_400),
            lastSeenAt: now.addingTimeInterval(-40 * 86_400),
            lastReinforcedAt: now.addingTimeInterval(-40 * 86_400),
            lastCorrectedAt: nil,
            activeFrom: now.addingTimeInterval(-70 * 86_400),
            activeUntil: nil
        ))

        let steward = ShadowLearningSteward(store: store, minNewMessages: 15)
        let result = await steward.consolidateIfDue(userId: "alex", now: now, force: true)

        XCTAssertEqual(result, .consolidated(patternCount: 1))
        let pattern = try XCTUnwrap(store.fetchPattern(
            userId: "alex",
            kind: .thinkingMove,
            label: "pain_test_for_product_scope"
        ))
        XCTAssertEqual(pattern.status, .fading)
    }

    private func insertUserMessage(
        _ nodeStore: NodeStore,
        nodeId: UUID,
        text: String,
        offset: TimeInterval
    ) throws {
        try nodeStore.insertMessage(Message(
            nodeId: nodeId,
            role: .user,
            content: text,
            timestamp: Date(timeIntervalSince1970: 1_000 + offset)
        ))
    }

    private func insertUserMessage(
        _ nodeStore: NodeStore,
        id: UUID,
        nodeId: UUID,
        text: String,
        timestamp: Date
    ) throws {
        try nodeStore.insertMessage(Message(
            id: id,
            nodeId: nodeId,
            role: .user,
            content: text,
            timestamp: timestamp
        ))
    }
}
