// Tests/NousTests/ProvocationOrchestrationTests.swift
import XCTest
@testable import Nous

final class ProvocationOrchestrationTests: XCTestCase {

    // A fake LLM service that returns a canned stream.
    final class CannedLLMService: LLMService {
        var replyOutput: String = "ok"
        var receivedSystems: [String?] = []
        var receivedSystem: String? { receivedSystems.first(where: { $0?.contains("BEHAVIOR:") == true }) ?? receivedSystems.first ?? nil }
        func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
            receivedSystems.append(system)
            let out = replyOutput
            return AsyncThrowingStream { cont in
                cont.yield(out); cont.finish()
            }
        }
    }

    // A fake judge whose next verdict is preset by the test.
    final class StubJudge: Judging {
        var nextVerdict: JudgeVerdict?
        var nextError: JudgeError?
        func judge(userMessage: String, citablePool: [CitableEntry], chatMode: ChatMode, provider: LLMProvider) async throws -> JudgeVerdict {
            if let err = nextError { throw err }
            return nextVerdict ?? JudgeVerdict(tensionExists: false, userState: .exploring, shouldProvoke: false, entryId: nil, reason: "stub default")
        }
    }

    var store: NodeStore!
    var telemetry: GovernanceTelemetryStore!
    var llm: CannedLLMService!
    var judge: StubJudge!
    var viewModel: ChatViewModel!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
        telemetry = GovernanceTelemetryStore(
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
            nodeStore: store
        )
        llm = CannedLLMService()
        judge = StubJudge()
        let vectorStore = VectorStore(nodeStore: store)
        let memoryService = UserMemoryService(nodeStore: store, llmServiceProvider: { self.llm })
        viewModel = ChatViewModel(
            nodeStore: store,
            vectorStore: vectorStore,
            embeddingService: EmbeddingService(),
            graphEngine: GraphEngine(nodeStore: store, vectorStore: vectorStore),
            userMemoryService: memoryService,
            userMemoryScheduler: UserMemoryScheduler(service: memoryService),
            llmServiceProvider: { self.llm },
            currentProviderProvider: { .claude },
            judgeLLMServiceFactory: { CannedLLMService() },
            provocationJudgeFactory: { _ in self.judge },
            governanceTelemetry: telemetry
        )
    }

    override func tearDown() {
        viewModel = nil; judge = nil; llm = nil; telemetry = nil; store = nil
        super.tearDown()
    }

    @MainActor
    func testShouldProvokeTrueInjectsFocusBlock() async throws {
        let entryId = UUID()
        let entry = MemoryEntry(
            id: entryId, scope: .global, kind: .preference, stability: .stable,
            content: "Alex refuses to compete on price.",
            sourceNodeIds: []
        )
        try store.insertMemoryEntry(entry)

        judge.nextVerdict = JudgeVerdict(
            tensionExists: true, userState: .deciding,
            shouldProvoke: true, entryId: entryId.uuidString,
            reason: "pricing conflict"
        )

        viewModel.inputText = "I'm going with the cheapest option on purpose"
        await viewModel.send()

        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("BEHAVIOR: PROVOCATIVE"),
                      "provocative profile block must be in main prompt")
        XCTAssertTrue(system.contains("RELEVANT PRIOR MEMORY"),
                      "focus block must be in main prompt")
        XCTAssertTrue(system.contains("compete on price"),
                      "raw entry text must be in main prompt")

        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.fallbackReason, .ok)
    }

    @MainActor
    func testShouldProvokeFalseUsesSupportiveProfile() async throws {
        judge.nextVerdict = JudgeVerdict(
            tensionExists: false, userState: .exploring,
            shouldProvoke: false, entryId: nil, reason: "no tension"
        )

        viewModel.inputText = "just thinking out loud"
        await viewModel.send()

        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("BEHAVIOR: SUPPORTIVE"))
        XCTAssertFalse(system.contains("RELEVANT PRIOR MEMORY"),
                       "no focus block when should_provoke is false")
    }

    @MainActor
    func testUnknownEntryIdForcesSupportiveAndLogsError() async throws {
        judge.nextVerdict = JudgeVerdict(
            tensionExists: true, userState: .deciding,
            shouldProvoke: true, entryId: "not-in-pool",
            reason: "ghost"
        )

        viewModel.inputText = "anything"
        await viewModel.send()

        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("BEHAVIOR: SUPPORTIVE"))
        XCTAssertFalse(system.contains("RELEVANT PRIOR MEMORY"))

        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertEqual(events.first?.fallbackReason, .unknownEntryId)
    }

    @MainActor
    func testJudgeTimeoutFallsBackToSupportive() async throws {
        judge.nextError = .timeout

        viewModel.inputText = "anything"
        await viewModel.send()

        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("BEHAVIOR: SUPPORTIVE"))

        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertEqual(events.first?.fallbackReason, .timeout)
    }

    @MainActor
    func testLocalProviderSkipsJudge() async throws {
        let vectorStore = VectorStore(nodeStore: store)
        let memoryService = UserMemoryService(nodeStore: store, llmServiceProvider: { self.llm })
        viewModel = ChatViewModel(
            nodeStore: store,
            vectorStore: vectorStore,
            embeddingService: EmbeddingService(),
            graphEngine: GraphEngine(nodeStore: store, vectorStore: vectorStore),
            userMemoryService: memoryService,
            userMemoryScheduler: UserMemoryScheduler(service: memoryService),
            llmServiceProvider: { self.llm },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            provocationJudgeFactory: { _ in
                // If this ever runs, the test fails loudly.
                let j = StubJudge()
                j.nextError = .apiError
                return j
            },
            governanceTelemetry: telemetry
        )

        viewModel.inputText = "anything"
        await viewModel.send()

        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("BEHAVIOR: SUPPORTIVE"))

        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertEqual(events.first?.fallbackReason, .providerLocal)
    }

    @MainActor
    func testCloudProviderWithoutJudgeServiceLogsUnavailable() async throws {
        let vectorStore = VectorStore(nodeStore: store)
        let memoryService = UserMemoryService(nodeStore: store, llmServiceProvider: { self.llm })
        viewModel = ChatViewModel(
            nodeStore: store,
            vectorStore: vectorStore,
            embeddingService: EmbeddingService(),
            graphEngine: GraphEngine(nodeStore: store, vectorStore: vectorStore),
            userMemoryService: memoryService,
            userMemoryScheduler: UserMemoryScheduler(service: memoryService),
            llmServiceProvider: { self.llm },
            currentProviderProvider: { .claude },
            judgeLLMServiceFactory: { nil },
            provocationJudgeFactory: { _ in
                let j = StubJudge()
                j.nextError = .apiError
                return j
            },
            governanceTelemetry: telemetry
        )

        viewModel.inputText = "anything"
        await viewModel.send()

        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("BEHAVIOR: SUPPORTIVE"))

        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertEqual(events.first?.fallbackReason, .judgeUnavailable)
    }
}
