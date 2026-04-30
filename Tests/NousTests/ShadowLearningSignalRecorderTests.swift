import XCTest
@testable import Nous

final class ShadowLearningSignalRecorderTests: XCTestCase {
    func testRecordsFirstPrinciplesObservationAndEvent() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let recorder = ShadowLearningSignalRecorder(store: store)
        let message = Message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000003001")!,
            nodeId: UUID(uuidString: "00000000-0000-0000-0000-000000003101")!,
            role: .user,
            content: "先用 first principles 拆一下这个产品判断",
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        try persist([message], in: nodeStore)

        try recorder.recordSignals(from: message, userId: "alex")

        let patterns = try store.fetchPatterns(userId: "alex")
        XCTAssertEqual(patterns.count, 1)
        XCTAssertEqual(patterns[0].label, "first_principles_decision_frame")
        XCTAssertEqual(patterns[0].status, .observed)
        XCTAssertEqual(patterns[0].evidenceMessageIds, [message.id])
        XCTAssertEqual(patterns[0].confidence, 0.51, accuracy: 0.0001)
        XCTAssertEqual(patterns[0].weight, 0.17, accuracy: 0.0001)

        let events = try store.fetchRecentEvents(userId: "alex", limit: 10)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].eventType, .observed)
        XCTAssertEqual(events[0].sourceMessageId, message.id)
        XCTAssertEqual(events[0].patternId, patterns[0].id)
    }

    func testRepeatedObservationReinforcesExistingPattern() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let recorder = ShadowLearningSignalRecorder(store: store)
        let first = userMessage(
            id: "00000000-0000-0000-0000-000000003011",
            content: "这个决定先看本质",
            timestamp: 1_000
        )
        let second = userMessage(
            id: "00000000-0000-0000-0000-000000003012",
            content: "再从根上拆一下",
            timestamp: 1_100
        )
        try persist([first, second], in: nodeStore)

        try recorder.recordSignals(from: first, userId: "alex")
        try recorder.recordSignals(from: second, userId: "alex")

        let pattern = try XCTUnwrap(store.fetchPattern(
            userId: "alex",
            kind: .thinkingMove,
            label: "first_principles_decision_frame"
        ))
        XCTAssertEqual(pattern.evidenceMessageIds, [first.id, second.id])

        let events = try store.fetchRecentEvents(userId: "alex", limit: 10)
        XCTAssertEqual(events.map(\.eventType), [.reinforced, .observed])
    }

    func testCorrectionWeakensMatchingPatternAndWritesCorrectionEvent() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let recorder = ShadowLearningSignalRecorder(store: store)
        let now = Date(timeIntervalSince1970: 2_000)
        try store.upsertPattern(
            ShadowLearningPattern(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000003201")!,
                userId: "alex",
                kind: .thinkingMove,
                label: "first_principles_decision_frame",
                summary: "Use first principles for product and architecture judgment.",
                promptFragment: "For product or architecture judgment, start from the base constraint before comparing existing patterns.",
                triggerHint: "product architecture decision first principles",
                confidence: 0.86,
                weight: 0.65,
                status: .strong,
                evidenceMessageIds: [],
                firstSeenAt: now.addingTimeInterval(-1_000),
                lastSeenAt: now.addingTimeInterval(-100),
                lastReinforcedAt: now.addingTimeInterval(-100),
                lastCorrectedAt: nil,
                activeFrom: now.addingTimeInterval(-500),
                activeUntil: nil
            )
        )
        let correction = Message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000003002")!,
            nodeId: UUID(uuidString: "00000000-0000-0000-0000-000000003102")!,
            role: .user,
            content: "这次别用第一性原理，先给我直觉判断",
            timestamp: now
        )
        try persist([correction], in: nodeStore)

        try recorder.recordSignals(from: correction, userId: "alex")

        let pattern = try XCTUnwrap(store.fetchPattern(
            userId: "alex",
            kind: .thinkingMove,
            label: "first_principles_decision_frame"
        ))
        XCTAssertEqual(pattern.status, .fading)
        XCTAssertEqual(pattern.lastCorrectedAt, now)
        XCTAssertLessThan(pattern.weight, 0.65)

        let events = try store.fetchRecentEvents(userId: "alex", limit: 10)
        XCTAssertEqual(events.first?.eventType, .corrected)
        XCTAssertEqual(events.first?.sourceMessageId, correction.id)
    }

    func testCorrectionWithoutExistingPatternDoesNotCreatePositiveObservation() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let recorder = ShadowLearningSignalRecorder(store: store)
        let correction = Message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000003003")!,
            nodeId: UUID(uuidString: "00000000-0000-0000-0000-000000003103")!,
            role: .user,
            content: "今天不要用 first principles，直接给判断",
            timestamp: Date(timeIntervalSince1970: 2_100)
        )
        try persist([correction], in: nodeStore)

        try recorder.recordSignals(from: correction, userId: "alex")

        XCTAssertTrue(try store.fetchPatterns(userId: "alex").isEmpty)
        XCTAssertTrue(try store.fetchRecentEvents(userId: "alex", limit: 10).isEmpty)
    }

    func testReplayingSameCorrectionDoesNotWeakenOrDuplicateEvents() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let recorder = ShadowLearningSignalRecorder(store: store)
        let now = Date(timeIntervalSince1970: 2_200)
        try store.upsertPattern(
            ShadowLearningPattern(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000003202")!,
                userId: "alex",
                kind: .thinkingMove,
                label: "first_principles_decision_frame",
                summary: "Use first principles for product and architecture judgment.",
                promptFragment: "For product or architecture judgment, start from the base constraint before comparing existing patterns.",
                triggerHint: "product architecture decision first principles",
                confidence: 0.86,
                weight: 0.65,
                status: .strong,
                evidenceMessageIds: [],
                firstSeenAt: now.addingTimeInterval(-1_000),
                lastSeenAt: now.addingTimeInterval(-100),
                lastReinforcedAt: now.addingTimeInterval(-100),
                lastCorrectedAt: nil,
                activeFrom: now.addingTimeInterval(-500),
                activeUntil: nil
            )
        )
        let correction = Message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000003004")!,
            nodeId: UUID(uuidString: "00000000-0000-0000-0000-000000003104")!,
            role: .user,
            content: "不要用第一性原理，直接给判断",
            timestamp: now
        )
        try persist([correction], in: nodeStore)

        try recorder.recordSignals(from: correction, userId: "alex")
        let firstCorrection = try XCTUnwrap(store.fetchPattern(
            userId: "alex",
            kind: .thinkingMove,
            label: "first_principles_decision_frame"
        ))

        try recorder.recordSignals(from: correction, userId: "alex")

        let replayedCorrection = try XCTUnwrap(store.fetchPattern(
            userId: "alex",
            kind: .thinkingMove,
            label: "first_principles_decision_frame"
        ))
        XCTAssertEqual(replayedCorrection, firstCorrection)

        let events = try store.fetchRecentEvents(userId: "alex", limit: 10)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.eventType, .corrected)
    }

    func testReplayingSameMessageDoesNotReinforceOrDuplicateEvents() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let recorder = ShadowLearningSignalRecorder(store: store)
        let message = userMessage(
            id: "00000000-0000-0000-0000-000000003013",
            content: "这个判断先从底层拆",
            timestamp: 1_200
        )
        try persist([message], in: nodeStore)

        try recorder.recordSignals(from: message, userId: "alex")
        let firstPattern = try XCTUnwrap(store.fetchPattern(
            userId: "alex",
            kind: .thinkingMove,
            label: "first_principles_decision_frame"
        ))

        try recorder.recordSignals(from: message, userId: "alex")

        let replayedPattern = try XCTUnwrap(store.fetchPattern(
            userId: "alex",
            kind: .thinkingMove,
            label: "first_principles_decision_frame"
        ))
        XCTAssertEqual(replayedPattern, firstPattern)

        let events = try store.fetchRecentEvents(userId: "alex", limit: 10)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.eventType, .observed)
    }

    func testIgnoresNonUserMessages() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let store = ShadowLearningStore(nodeStore: nodeStore)
        let recorder = ShadowLearningSignalRecorder(store: store)
        let assistantMessage = Message(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000003021")!,
            nodeId: UUID(uuidString: "00000000-0000-0000-0000-000000003121")!,
            role: .assistant,
            content: "Use first principles here.",
            timestamp: Date(timeIntervalSince1970: 3_000)
        )
        try persist([assistantMessage], in: nodeStore)

        try recorder.recordSignals(from: assistantMessage, userId: "alex")

        XCTAssertTrue(try store.fetchPatterns(userId: "alex").isEmpty)
        XCTAssertTrue(try store.fetchRecentEvents(userId: "alex", limit: 10).isEmpty)
    }

    private func userMessage(id: String, content: String, timestamp: TimeInterval) -> Message {
        Message(
            id: UUID(uuidString: id)!,
            nodeId: UUID(uuidString: "00000000-0000-0000-0000-000000003111")!,
            role: .user,
            content: content,
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
    }

    private func persist(_ messages: [Message], in nodeStore: NodeStore) throws {
        guard let nodeId = messages.first?.nodeId else { return }
        try nodeStore.insertNode(NousNode(id: nodeId, type: .conversation, title: "Shadow test"))
        for message in messages {
            try nodeStore.insertMessage(message)
        }
    }
}
