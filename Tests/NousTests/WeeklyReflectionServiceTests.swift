import XCTest
@testable import Nous

// MARK: - Fake LLM

private final class FakeStructuredLLM: StructuredLLMClient {
    enum Outcome {
        case success(text: String, usage: GeminiUsageMetadata?)
        case failure(Error)
    }

    var nextOutcome: Outcome = .success(text: #"{"claims":[]}"#, usage: nil)
    private(set) var callCount = 0
    private(set) var lastSystem: String?
    private(set) var lastUserContent: String?

    func generateStructured(
        messages: [LLMMessage],
        system: String?,
        responseSchema: [String: Any],
        temperature: Double
    ) async throws -> (text: String, usage: GeminiUsageMetadata?) {
        callCount += 1
        lastSystem = system
        lastUserContent = messages.last?.content
        switch nextOutcome {
        case .success(let text, let usage):
            return (text, usage)
        case .failure(let err):
            throw err
        }
    }
}

private enum FakeError: Error { case boom }

// MARK: - Tests

final class WeeklyReflectionServiceTests: XCTestCase {

    private var store: NodeStore!
    private var llm: FakeStructuredLLM!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
        llm = FakeStructuredLLM()
    }

    override func tearDown() {
        store = nil
        llm = nil
        super.tearDown()
    }

    // MARK: Pure helpers

    func testPreviousCompletedWeekReturnsISOMondayPair() throws {
        // 2026-04-22 is a Wednesday. Previous completed ISO week: 2026-04-13 Mon → 2026-04-20 Mon.
        let wed = makeDate(2026, 4, 22, hour: 14)
        let (start, end) = try XCTUnwrap(WeeklyReflectionService.previousCompletedWeek(now: wed))

        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current
        let startComp = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: start)
        let endComp = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: end)

        // ISO weekday: Monday = 2 in Gregorian mapping, but Calendar(.iso8601) gives Monday=2 still.
        // We check span == 7 days and hours == 0.
        let span = end.timeIntervalSince(start)
        XCTAssertEqual(span, 7 * 24 * 3600, accuracy: 3600)  // tolerate DST edges
        XCTAssertEqual(startComp.hour, 0)
        XCTAssertEqual(endComp.hour, 0)
        XCTAssertLessThan(start, wed)
        XCTAssertLessThanOrEqual(end, wed)
    }

    func testEstimatedCostCentsNilUsageReturnsZero() {
        XCTAssertEqual(WeeklyReflectionService.estimatedCostCents(usage: nil), 0)
    }

    func testEstimatedCostCentsRoundsInputAndOutputSeparately() {
        // 1M prompt tokens @ $1.25/M = 125¢
        // 500K (thought+candidate) tokens @ $10/M = 500¢
        // Total = 625¢
        let usage = GeminiUsageMetadata(
            promptTokenCount: 1_000_000,
            cachedContentTokenCount: 0,
            candidatesTokenCount: 300_000,
            thoughtsTokenCount: 200_000,
            totalTokenCount: 1_500_000
        )
        XCTAssertEqual(WeeklyReflectionService.estimatedCostCents(usage: usage), 625)
    }

    func testEstimatedCostCentsHandlesNilOptionalFields() {
        let usage = GeminiUsageMetadata(
            promptTokenCount: 1_000_000,
            cachedContentTokenCount: 0,
            candidatesTokenCount: nil,
            thoughtsTokenCount: nil,
            totalTokenCount: nil
        )
        XCTAssertEqual(WeeklyReflectionService.estimatedCostCents(usage: usage), 125)
    }

    // MARK: Guard #1 — not enough messages

    func testNotEnoughMessagesWritesRejectedAllGenericAndSkipsLLM() async throws {
        let weekStart = makeDate(2026, 4, 13)
        let weekEnd = makeDate(2026, 4, 20)

        // Seed 5 messages — below minMessagesForRun (10).
        try seedConversation(
            projectId: nil,
            timestamps: (0..<5).map { weekStart.addingTimeInterval(TimeInterval($0) * 3600) }
        )

        let service = WeeklyReflectionService(nodeStore: store, llm: llm, now: { self.now })
        let result = try await service.runForWeek(projectId: nil, weekStart: weekStart, weekEnd: weekEnd)

        let run = try XCTUnwrap(result?.run)
        XCTAssertEqual(run.status, .rejectedAll)
        XCTAssertEqual(run.rejectionReason, .generic)
        XCTAssertEqual(run.costCents, 0)
        XCTAssertEqual(result?.claims.count, 0)
        XCTAssertEqual(llm.callCount, 0, "must not waste a Gemini call when messages < threshold")
    }

    // MARK: Idempotency

    func testSecondCallForSameWeekReturnsNil() async throws {
        let weekStart = makeDate(2026, 4, 13)
        let weekEnd = makeDate(2026, 4, 20)
        try seedConversation(projectId: nil, timestamps: [weekStart])  // 1 msg → rejected_all/generic

        let service = WeeklyReflectionService(nodeStore: store, llm: llm, now: { self.now })
        _ = try await service.runForWeek(projectId: nil, weekStart: weekStart, weekEnd: weekEnd)
        let second = try await service.runForWeek(projectId: nil, weekStart: weekStart, weekEnd: weekEnd)

        XCTAssertNil(second, "existing run must short-circuit the pipeline")
    }

    // MARK: Happy path

    func testHappyPathPersistsSuccessClaimsAndEvidence() async throws {
        let weekStart = makeDate(2026, 4, 13)
        let weekEnd = makeDate(2026, 4, 20)

        // Seed two separate conversations so the claim's evidence spans ≥2 distinct nodeIds,
        // satisfying the distinct-conversation rule added in Task 7.
        let msgIdsA = (0..<6).map { _ in UUID() }
        let msgIdsB = (0..<6).map { _ in UUID() }
        try seedConversation(
            projectId: nil,
            timestamps: msgIdsA.enumerated().map { i, _ in weekStart.addingTimeInterval(TimeInterval(i) * 3600) },
            messageIds: msgIdsA
        )
        try seedConversation(
            projectId: nil,
            timestamps: msgIdsB.enumerated().map { i, _ in weekStart.addingTimeInterval(TimeInterval(i + 6) * 3600) },
            messageIds: msgIdsB
        )

        // Evidence drawn from two different conversations (nodeA and nodeB).
        let id0 = msgIdsA[0].uuidString   // nodeA
        let id1 = msgIdsA[1].uuidString   // nodeA
        let id2 = msgIdsB[0].uuidString   // nodeB — crosses the conversation boundary
        llm.nextOutcome = .success(
            text: #"""
            {"claims":[
              {"claim":"real pattern","confidence":0.8,"supporting_turn_ids":["\#(id0)","\#(id1)","\#(id2)"],"why_non_obvious":"reason"}
            ]}
            """#,
            usage: GeminiUsageMetadata(
                promptTokenCount: 10_000,
                cachedContentTokenCount: 0,
                candidatesTokenCount: 2_000,
                thoughtsTokenCount: 0,
                totalTokenCount: 12_000
            )
        )

        let service = WeeklyReflectionService(nodeStore: store, llm: llm, now: { self.now })
        let result = try await service.runForWeek(projectId: nil, weekStart: weekStart, weekEnd: weekEnd)

        let res = try XCTUnwrap(result)
        XCTAssertEqual(res.run.status, .success)
        XCTAssertNil(res.run.rejectionReason)
        XCTAssertEqual(res.claims.count, 1)
        XCTAssertEqual(res.claims[0].claim, "real pattern")
        XCTAssertEqual(res.evidence.count, 3)
        // Cost = 10_000 * 1.25/M + 2_000 * 10/M = 1.25¢ + 2¢ = rounded 3¢.
        XCTAssertEqual(res.run.costCents, 3)

        // Round-trip: claims are queryable via the normal retrieval API.
        let fetched = try store.fetchActiveReflectionClaims(projectId: nil)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].claim, "real pattern")
    }

    func test_postsReflectionRunCompletedNotificationOnSuccess() async throws {
        let weekStart = makeDate(2026, 4, 13)
        let weekEnd   = makeDate(2026, 4, 20)

        let msgIdsA = (0..<6).map { _ in UUID() }
        let msgIdsB = (0..<6).map { _ in UUID() }
        try seedConversation(
            projectId: nil,
            timestamps: msgIdsA.enumerated().map { i, _ in weekStart.addingTimeInterval(TimeInterval(i) * 3600) },
            messageIds: msgIdsA
        )
        try seedConversation(
            projectId: nil,
            timestamps: msgIdsB.enumerated().map { i, _ in weekStart.addingTimeInterval(TimeInterval(i + 6) * 3600) },
            messageIds: msgIdsB
        )

        let id0 = msgIdsA[0].uuidString
        let id1 = msgIdsA[1].uuidString
        let id2 = msgIdsB[0].uuidString
        llm.nextOutcome = .success(
            text: #"""
            {"claims":[
              {"claim":"notification test","confidence":0.9,"supporting_turn_ids":["\#(id0)","\#(id1)","\#(id2)"],"why_non_obvious":"reason"}
            ]}
            """#,
            usage: nil
        )

        let exp = expectation(forNotification: .reflectionRunCompleted, object: nil, handler: nil)
        let service = WeeklyReflectionService(nodeStore: store, llm: llm, now: { self.now })
        _ = try await service.runForWeek(projectId: nil, weekStart: weekStart, weekEnd: weekEnd)
        await fulfillment(of: [exp], timeout: 5.0)
    }

    // MARK: Guard #2 — LLM failure

    func testLLMFailurePersistsFailedApiErrorAndRethrows() async throws {
        let weekStart = makeDate(2026, 4, 13)
        let weekEnd = makeDate(2026, 4, 20)
        try seedConversation(
            projectId: nil,
            timestamps: (0..<12).map { weekStart.addingTimeInterval(TimeInterval($0) * 3600) }
        )
        llm.nextOutcome = .failure(FakeError.boom)

        let service = WeeklyReflectionService(nodeStore: store, llm: llm, now: { self.now })

        do {
            _ = try await service.runForWeek(projectId: nil, weekStart: weekStart, weekEnd: weekEnd)
            XCTFail("expected throw")
        } catch WeeklyReflectionService.ServiceError.llmFailure {
            // expected
        }

        let latest = try XCTUnwrap(try store.latestReflectionRun(projectId: nil))
        XCTAssertEqual(latest.status, .failed)
        XCTAssertEqual(latest.rejectionReason, .apiError)
        XCTAssertEqual(latest.costCents, 0, "failed calls have no usable usage metadata")
    }

    // MARK: Guard #3 — malformed validator output

    func testMalformedJSONPersistsFailedApiErrorAndRethrows() async throws {
        let weekStart = makeDate(2026, 4, 13)
        let weekEnd = makeDate(2026, 4, 20)
        try seedConversation(
            projectId: nil,
            timestamps: (0..<12).map { weekStart.addingTimeInterval(TimeInterval($0) * 3600) }
        )
        llm.nextOutcome = .success(
            text: "not-json-at-all",
            usage: GeminiUsageMetadata(
                promptTokenCount: 10_000,
                cachedContentTokenCount: 0,
                candidatesTokenCount: 100,
                thoughtsTokenCount: 0,
                totalTokenCount: 10_100
            )
        )

        let service = WeeklyReflectionService(nodeStore: store, llm: llm, now: { self.now })

        do {
            _ = try await service.runForWeek(projectId: nil, weekStart: weekStart, weekEnd: weekEnd)
            XCTFail("expected throw")
        } catch WeeklyReflectionService.ServiceError.validatorMalformed {
            // expected
        }

        let latest = try XCTUnwrap(try store.latestReflectionRun(projectId: nil))
        XCTAssertEqual(latest.status, .failed)
        XCTAssertEqual(latest.rejectionReason, .apiError)
        // Cost still captured — we paid Gemini even though the payload was bad.
        XCTAssertGreaterThan(latest.costCents ?? 0, 0)
    }

    // MARK: Validator rejection → rejected_all with reason

    func testAllClaimsUngroundedPersistsRejectedAllUnsupported() async throws {
        let weekStart = makeDate(2026, 4, 13)
        let weekEnd = makeDate(2026, 4, 20)
        try seedConversation(
            projectId: nil,
            timestamps: (0..<12).map { weekStart.addingTimeInterval(TimeInterval($0) * 3600) }
        )

        // Model returns claims citing IDs that don't exist in the fixture.
        llm.nextOutcome = .success(
            text: #"""
            {"claims":[
              {"claim":"hallucinated","confidence":0.9,"supporting_turn_ids":["fake-1","fake-2"],"why_non_obvious":"w"}
            ]}
            """#,
            usage: GeminiUsageMetadata(
                promptTokenCount: 10_000,
                cachedContentTokenCount: 0,
                candidatesTokenCount: 500,
                thoughtsTokenCount: 0,
                totalTokenCount: 10_500
            )
        )

        let service = WeeklyReflectionService(nodeStore: store, llm: llm, now: { self.now })
        let result = try await service.runForWeek(projectId: nil, weekStart: weekStart, weekEnd: weekEnd)
        let res = try XCTUnwrap(result)
        XCTAssertEqual(res.run.status, .rejectedAll)
        XCTAssertEqual(res.run.rejectionReason, .unsupported)
        XCTAssertTrue(res.claims.isEmpty)
    }

    // MARK: - Helpers

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        return cal.date(from: comps)!
    }

    private func seedConversation(
        projectId: UUID?,
        timestamps: [Date],
        messageIds: [UUID]? = nil
    ) throws {
        let node = NousNode(
            type: .conversation,
            title: "Fixture chat",
            content: "",
            projectId: projectId
        )
        try store.insertNode(node)

        for (i, ts) in timestamps.enumerated() {
            let id = messageIds?[i] ?? UUID()
            let msg = Message(
                id: id,
                nodeId: node.id,
                role: i % 2 == 0 ? .user : .assistant,
                content: "message \(i)",
                timestamp: ts,
                thinkingContent: nil
            )
            try store.insertMessage(msg)
        }
    }
}
