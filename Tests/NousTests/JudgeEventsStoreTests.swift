import XCTest
@testable import Nous

final class JudgeEventsStoreTests: XCTestCase {

    var store: NodeStore!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func makeEvent(
        id: UUID = UUID(),
        ts: Date = Date(),
        nodeId: UUID = UUID(),
        fallback: JudgeFallbackReason = .ok
    ) -> JudgeEvent {
        let verdict = JudgeVerdict(
            tensionExists: fallback == .ok,
            userState: .exploring,
            shouldProvoke: fallback == .ok,
            entryId: fallback == .ok ? UUID().uuidString : nil,
            reason: "test",
            inferredMode: .companion
        )
        let verdictJSON = String(data: try! JSONEncoder().encode(verdict), encoding: .utf8)!
        return JudgeEvent(
            id: id, ts: ts, nodeId: nodeId, messageId: nil,
            chatMode: .companion, provider: .claude,
            verdictJSON: verdictJSON, fallbackReason: fallback,
            userFeedback: nil, feedbackTs: nil
        )
    }

    func testAppendAndFetchRoundTrip() throws {
        let event = makeEvent()
        try store.appendJudgeEvent(event)

        let fetched = try store.fetchJudgeEvent(id: event.id)
        XCTAssertEqual(fetched?.id, event.id)
        XCTAssertEqual(fetched?.chatMode, .companion)
        XCTAssertEqual(fetched?.provider, .claude)
        XCTAssertEqual(fetched?.fallbackReason, .ok)
    }

    func testRecentJudgeEventsReturnsNewestFirst() throws {
        // Use explicit monotonic timestamps — two Date() calls in quick succession can be equal
        // on some hardware, and "ORDER BY ts DESC" doesn't guarantee insertion order within a tie.
        let baseTs = Date()
        let ids = (0..<3).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            try store.appendJudgeEvent(makeEvent(
                id: id,
                ts: baseTs.addingTimeInterval(TimeInterval(i))
            ))
        }
        let recent = try store.recentJudgeEvents(limit: 10, filter: .none)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.map(\.id), ids.reversed())
    }

    func testRecentJudgeEventsFiltersByFallback() throws {
        try store.appendJudgeEvent(makeEvent(fallback: .ok))
        try store.appendJudgeEvent(makeEvent(fallback: .timeout))
        try store.appendJudgeEvent(makeEvent(fallback: .badJSON))

        let okOnly = try store.recentJudgeEvents(limit: 10, filter: .fallback(.ok))
        XCTAssertEqual(okOnly.count, 1)
        XCTAssertEqual(okOnly.first?.fallbackReason, .ok)
    }

    func testUpdateFeedbackPersists() throws {
        let event = makeEvent()
        try store.appendJudgeEvent(event)
        try store.updateJudgeEventFeedback(id: event.id, feedback: .down, at: Date())

        let fetched = try store.fetchJudgeEvent(id: event.id)
        XCTAssertEqual(fetched?.userFeedback, .down)
        XCTAssertNotNil(fetched?.feedbackTs)
    }

    func testGovernanceStoreDelegatesToNodeStore() throws {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let telemetry = GovernanceTelemetryStore(defaults: defaults, nodeStore: store)

        let event = makeEvent()
        telemetry.appendJudgeEvent(event)

        let fetched = try store.fetchJudgeEvent(id: event.id)
        XCTAssertEqual(fetched?.id, event.id)

        telemetry.recordFeedback(eventId: event.id, feedback: .up)
        XCTAssertEqual(try store.fetchJudgeEvent(id: event.id)?.userFeedback, .up)
    }

    func testGovernanceStoreExposesRecentEvents() throws {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let telemetry = GovernanceTelemetryStore(defaults: defaults, nodeStore: store)

        telemetry.appendJudgeEvent(makeEvent(fallback: .ok))
        telemetry.appendJudgeEvent(makeEvent(fallback: .timeout))

        let events = telemetry.recentJudgeEvents(limit: 10, filter: .none)
        XCTAssertEqual(events.count, 2)
    }

    func testRecentJudgeEventsFiltersByProvocationKind() throws {
        let nodeId = UUID()
        func encoded(_ kind: ProvocationKind, shouldProvoke: Bool, entryId: String?) -> String {
            var v = JudgeVerdict(
                tensionExists: shouldProvoke,
                userState: shouldProvoke ? .deciding : .exploring,
                shouldProvoke: shouldProvoke,
                entryId: entryId,
                reason: "fixture",
                inferredMode: .strategist
            )
            v.provocationKind = kind
            let data = try! JSONEncoder().encode(v)
            return String(data: data, encoding: .utf8)!
        }

        try store.appendJudgeEvent(JudgeEvent(
            id: UUID(), ts: Date(timeIntervalSince1970: 10),
            nodeId: nodeId, messageId: nil,
            chatMode: .strategist, provider: .openai,
            verdictJSON: encoded(.contradiction, shouldProvoke: true, entryId: "E1"),
            fallbackReason: .ok, userFeedback: nil, feedbackTs: nil
        ))
        try store.appendJudgeEvent(JudgeEvent(
            id: UUID(), ts: Date(timeIntervalSince1970: 20),
            nodeId: nodeId, messageId: nil,
            chatMode: .strategist, provider: .openai,
            verdictJSON: encoded(.spark, shouldProvoke: true, entryId: "E2"),
            fallbackReason: .ok, userFeedback: nil, feedbackTs: nil
        ))
        try store.appendJudgeEvent(JudgeEvent(
            id: UUID(), ts: Date(timeIntervalSince1970: 30),
            nodeId: nodeId, messageId: nil,
            chatMode: .companion, provider: .openai,
            verdictJSON: encoded(.neutral, shouldProvoke: false, entryId: nil),
            fallbackReason: .ok, userFeedback: nil, feedbackTs: nil
        ))

        let contradictionOnly = try store.recentJudgeEvents(
            limit: 50,
            filter: .provocationKind(.contradiction)
        )
        XCTAssertEqual(contradictionOnly.count, 1)
        XCTAssertTrue(contradictionOnly[0].verdictJSON.contains("\"provocation_kind\":\"contradiction\""))

        let sparkOnly = try store.recentJudgeEvents(
            limit: 50,
            filter: .provocationKind(.spark)
        )
        XCTAssertEqual(sparkOnly.count, 1)
    }
}
