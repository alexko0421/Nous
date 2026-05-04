import XCTest
@testable import Nous

final class BackgroundAIJobGovernanceTests: XCTestCase {

    func testCatalogDeclaresLLMBackedMaintenanceJobs() {
        let recipes = BackgroundAIJobCatalog.all
        let ids = Set(recipes.map(\.id))

        XCTAssertEqual(ids, [
            .conversationTitleBackfill,
            .memoryGraphMessageBackfill,
            .weeklyReflection,
            .galaxyRelationRefinement
        ])

        for recipe in recipes {
            XCTAssertTrue(recipe.isComplete, "\(recipe.id.rawValue) must declare its full cookbook contract")
            XCTAssertFalse(recipe.purpose.isEmpty)
            XCTAssertFalse(recipe.inputScope.isEmpty)
            XCTAssertFalse(recipe.outputContract.isEmpty)
            XCTAssertFalse(recipe.privacyBoundary.isEmpty)
            XCTAssertFalse(recipe.idempotencyKey.isEmpty)
        }
    }

    func testTelemetryStoreKeepsRecentRunsAndSummarizesByJob() {
        let suiteName = "BackgroundAIJobGovernanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BackgroundAIJobTelemetryStore(defaults: defaults, maxRecords: 2)
        store.record(run(
            jobId: .conversationTitleBackfill,
            status: .completed,
            endedAt: Date(timeIntervalSince1970: 1),
            detail: "first"
        ))
        store.record(run(
            jobId: .weeklyReflection,
            status: .failed,
            endedAt: Date(timeIntervalSince1970: 2),
            detail: "second"
        ))
        store.record(run(
            jobId: .weeklyReflection,
            status: .completed,
            endedAt: Date(timeIntervalSince1970: 3),
            detail: "third"
        ))

        XCTAssertEqual(store.recentRuns(limit: 10).map(\.detail), ["third", "second"])

        let summary = store.summary(for: .weeklyReflection)
        XCTAssertEqual(summary.runCount, 2)
        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.skippedCount, 0)
        XCTAssertEqual(summary.lastRun?.detail, "third")
    }

    func testConversationTitleBackfillRecordsBackgroundRun() async throws {
        let suiteName = "BackgroundAIJobGovernanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let telemetry = BackgroundAIJobTelemetryStore(defaults: defaults)
        let store = try NodeStore(path: ":memory:")

        let legacyPrompt = "Should I move to New York or Austin for the next phase?"
        let chat = NousNode(type: .conversation, title: String(legacyPrompt.prefix(40)))
        try store.insertNode(chat)
        try store.insertMessage(Message(nodeId: chat.id, role: .user, content: legacyPrompt))
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: chat.id,
                kind: .thread,
                stability: .temporary,
                content: "- Alex is deciding whether to move to New York or Austin",
                sourceNodeIds: [chat.id]
            )
        )

        let service = ConversationTitleBackfillService(
            nodeStore: store,
            llmServiceProvider: { FixedLLM(output: "move to New York or Austin") },
            backgroundTelemetry: telemetry
        )

        await service.runIfNeeded()

        let run = try XCTUnwrap(telemetry.lastRun(for: .conversationTitleBackfill))
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.inputCount, 1)
        XCTAssertEqual(run.outputCount, 1)
        XCTAssertEqual(run.detail, "updated_titles=1")
    }

    func testMemoryGraphMessageBackfillRecordsLLMUnavailableSkip() async throws {
        let suiteName = "BackgroundAIJobGovernanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let telemetry = BackgroundAIJobTelemetryStore(defaults: defaults)
        let store = try NodeStore(path: ":memory:")

        let service = MemoryGraphMessageBackfillService(
            nodeStore: store,
            llmServiceProvider: { nil },
            backgroundTelemetry: telemetry
        )

        let report = await service.runIfNeeded(maxConversations: 4)

        XCTAssertEqual(report, MemoryGraphMessageBackfillReport())
        let run = try XCTUnwrap(telemetry.lastRun(for: .memoryGraphMessageBackfill))
        XCTAssertEqual(run.status, .skipped)
        XCTAssertEqual(run.inputCount, 0)
        XCTAssertEqual(run.outputCount, 0)
        XCTAssertEqual(run.detail, "llm_unavailable")
    }

    func testWeeklyReflectionRecordsCompletedBackgroundRun() async throws {
        let suiteName = "BackgroundAIJobGovernanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let telemetry = BackgroundAIJobTelemetryStore(defaults: defaults)
        let store = try NodeStore(path: ":memory:")
        let llm = StructuredLLMForBackgroundTest()
        let weekStart = makeDate(2026, 4, 13)
        let weekEnd = makeDate(2026, 4, 20)
        let messageIds = (0..<12).map { _ in UUID() }

        try seedConversation(
            store: store,
            timestamps: messageIds.enumerated().map { index, _ in
                weekStart.addingTimeInterval(TimeInterval(index) * 3600)
            },
            messageIds: messageIds
        )

        llm.nextText = #"""
        {"claims":[
          {"claim":"real pattern","confidence":0.8,"supporting_turn_ids":["\#(messageIds[0].uuidString)","\#(messageIds[1].uuidString)"],"why_non_obvious":"reason"}
        ]}
        """#

        let service = WeeklyReflectionService(
            nodeStore: store,
            llm: llm,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            backgroundTelemetry: telemetry
        )

        _ = try await service.runForWeek(projectId: nil, weekStart: weekStart, weekEnd: weekEnd)

        let run = try XCTUnwrap(telemetry.lastRun(for: .weeklyReflection))
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.inputCount, 12)
        XCTAssertEqual(run.outputCount, 1)
        XCTAssertEqual(run.costCents, 3)
        XCTAssertEqual(run.detail, "claims=1")
    }

    private func run(
        jobId: BackgroundAIJobID,
        status: BackgroundAIJobStatus,
        endedAt: Date,
        detail: String
    ) -> BackgroundAIJobRunRecord {
        BackgroundAIJobRunRecord(
            id: UUID(),
            jobId: jobId,
            status: status,
            startedAt: endedAt.addingTimeInterval(-1),
            endedAt: endedAt,
            inputCount: 1,
            outputCount: status == .completed ? 1 : 0,
            detail: detail,
            costCents: nil
        )
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone.current
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return cal.date(from: comps)!
    }

    private func seedConversation(
        store: NodeStore,
        timestamps: [Date],
        messageIds: [UUID]
    ) throws {
        let node = NousNode(type: .conversation, title: "Fixture chat")
        try store.insertNode(node)

        for (index, timestamp) in timestamps.enumerated() {
            try store.insertMessage(Message(
                id: messageIds[index],
                nodeId: node.id,
                role: index % 2 == 0 ? .user : .assistant,
                content: "message \(index)",
                timestamp: timestamp
            ))
        }
    }
}

private struct FixedLLM: LLMService {
    let output: String

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}

private final class StructuredLLMForBackgroundTest: StructuredLLMClient {
    var nextText = #"{"claims":[]}"#

    func generateStructured(
        messages: [LLMMessage],
        system: String?,
        responseSchema: [String: Any],
        temperature: Double
    ) async throws -> (text: String, usage: GeminiUsageMetadata?) {
        (
            nextText,
            GeminiUsageMetadata(
                promptTokenCount: 10_000,
                cachedContentTokenCount: 0,
                candidatesTokenCount: 2_000,
                thoughtsTokenCount: 0,
                totalTokenCount: 12_000
            )
        )
    }
}
