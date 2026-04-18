// Tests/NousTests/ProvocationOrchestrationTests.swift
import XCTest
@testable import Nous

final class ProvocationOrchestrationTests: XCTestCase {

    // A fake LLM service that returns a canned stream.
    final class CannedLLMService: LLMService {
        var replyOutput: String = "ok"
        var receivedSystems: [String?] = []
        var receivedSystem: String? { receivedSystems.first(where: { $0?.contains("BEHAVIOR:") == true }) ?? receivedSystems.first ?? nil }
        var nextError: Error?
        func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
            receivedSystems.append(system)
            if let err = nextError { throw err }
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
        var previousModeHistory: [ChatMode?] = []

        func judge(userMessage: String, citablePool: [CitableEntry], previousMode: ChatMode?, provider: LLMProvider) async throws -> JudgeVerdict {
            previousModeHistory.append(previousMode)
            if let err = nextError { throw err }
            return nextVerdict ?? JudgeVerdict(tensionExists: false, userState: .exploring, shouldProvoke: false, entryId: nil, reason: "stub default", inferredMode: .companion)
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

    func testJudgeVerdictParsesInferredMode() throws {
        let json = """
        {
          "tension_exists": true,
          "user_state": "deciding",
          "should_provoke": true,
          "entry_id": "E1",
          "reason": "pricing conflict",
          "inferred_mode": "strategist"
        }
        """.data(using: .utf8)!

        let verdict = try JSONDecoder().decode(JudgeVerdict.self, from: json)

        XCTAssertEqual(verdict.inferredMode, .strategist)
        XCTAssertEqual(verdict.shouldProvoke, true)
        XCTAssertEqual(verdict.userState, .deciding)
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
            reason: "pricing conflict", inferredMode: .companion
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
            shouldProvoke: false, entryId: nil, reason: "no tension", inferredMode: .companion
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
            reason: "ghost", inferredMode: .companion
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

    @MainActor
    func testExternalCancellationShortCircuitsJudge() async throws {
        // A judge that sleeps long enough for us to fire cancelInFlightJudge() mid-call.
        final class SlowJudge: Judging {
            func judge(userMessage: String, citablePool: [CitableEntry],
                       previousMode: ChatMode?, provider: LLMProvider) async throws -> JudgeVerdict {
                try await Task.sleep(nanoseconds: 2_000_000_000)  // 2s — long enough to cancel
                try Task.checkCancellation()  // propagate cancel even if sleep was swallowed
                return JudgeVerdict(tensionExists: false, userState: .exploring,
                                    shouldProvoke: false, entryId: nil, reason: "slow", inferredMode: .companion)
            }
        }
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
            provocationJudgeFactory: { _ in SlowJudge() },
            governanceTelemetry: telemetry
        )

        viewModel.inputText = "test"
        // Fire send() without awaiting; cancel shortly after so the judge is interrupted.
        let sendTask = Task { await self.viewModel.send() }
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms — judge is now sleeping inside
        viewModel.cancelInFlightJudge()
        await sendTask.value

        // The cancelled judge must not have produced a main-LLM call
        // (send() returns early in the CancellationError branch, before llm.generate()).
        XCTAssertNil(llm.receivedSystem,
                     "cancelled judge must short-circuit send() before the main LLM call")

        // And no judge event should be logged for a cancelled turn.
        let events = telemetry.recentJudgeEvents(limit: 10, filter: .none)
        XCTAssertEqual(events.count, 0, "cancelled judge must not log any judge event")
    }

    @MainActor
    func testLoadConversationCancelsInFlightJudge() async throws {
        final class SlowJudge: Judging {
            var wasCancelled = false
            func judge(userMessage: String, citablePool: [CitableEntry],
                       previousMode: ChatMode?, provider: LLMProvider) async throws -> JudgeVerdict {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    wasCancelled = true
                    throw CancellationError()
                }
                return JudgeVerdict(tensionExists: false, userState: .exploring,
                                    shouldProvoke: false, entryId: nil, reason: "slow", inferredMode: .companion)
            }
        }
        let slowJudge = SlowJudge()
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
            provocationJudgeFactory: { _ in slowJudge },
            governanceTelemetry: telemetry
        )

        viewModel.inputText = "first"
        let sendTask = Task { await self.viewModel.send() }
        try await Task.sleep(nanoseconds: 100_000_000)  // let the judge enter its sleep

        // User navigates to a different conversation.
        let otherNode = NousNode(type: .conversation, title: "other", projectId: nil)
        try store.insertNode(otherNode)
        viewModel.loadConversation(otherNode)

        await sendTask.value

        XCTAssertTrue(slowJudge.wasCancelled,
                      "loadConversation must cancel the in-flight judge task")
        XCTAssertNil(llm.receivedSystem,
                     "cancelled judge must short-circuit send() before main LLM call")
        let events = telemetry.recentJudgeEvents(limit: 10, filter: .none)
        XCTAssertEqual(events.count, 0,
                       "cancelled judge must not log any judge event")
    }

    @MainActor
    func testStartNewConversationCancelsInFlightJudge() async throws {
        final class SlowJudge: Judging {
            var wasCancelled = false
            func judge(userMessage: String, citablePool: [CitableEntry],
                       previousMode: ChatMode?, provider: LLMProvider) async throws -> JudgeVerdict {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { wasCancelled = true; throw CancellationError() }
                return JudgeVerdict(tensionExists: false, userState: .exploring,
                                    shouldProvoke: false, entryId: nil, reason: "slow", inferredMode: .companion)
            }
        }
        let slowJudge = SlowJudge()
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
            provocationJudgeFactory: { _ in slowJudge },
            governanceTelemetry: telemetry
        )

        viewModel.inputText = "first"
        let sendTask = Task { await self.viewModel.send() }
        try await Task.sleep(nanoseconds: 100_000_000)

        viewModel.startNewConversation(title: "fresh")

        await sendTask.value

        XCTAssertTrue(slowJudge.wasCancelled,
                      "startNewConversation must cancel the in-flight judge task")
    }

    @MainActor
    func testFeedbackUpdatesEvent() async throws {
        let entryId = UUID()
        try store.insertMemoryEntry(MemoryEntry(
            id: entryId, scope: .global, kind: .preference, stability: .stable,
            content: "don't compete on price", sourceNodeIds: []
        ))
        judge.nextVerdict = JudgeVerdict(
            tensionExists: true, userState: .deciding,
            shouldProvoke: true, entryId: entryId.uuidString, reason: "conflict", inferredMode: .companion
        )
        viewModel.inputText = "going cheap"
        await viewModel.send()

        guard let assistantMessage = viewModel.messages.last(where: { $0.role == .assistant }),
              let eventId = viewModel.judgeEventId(forMessageId: assistantMessage.id)
        else {
            XCTFail("expected a judge event for the provoked assistant message")
            return
        }

        viewModel.recordFeedback(forMessageId: assistantMessage.id, feedback: .down)

        let updated = try store.fetchJudgeEvent(id: eventId)
        XCTAssertEqual(updated?.userFeedback, .down)
    }

    func testLatestChatModeReturnsNewestRow() throws {
        let nodeId = UUID()
        let node = NousNode(id: nodeId, type: .conversation, title: "t")
        try store.insertNode(node)

        let now = Date()
        let e1 = JudgeEvent(
            id: UUID(), ts: now.addingTimeInterval(-10), nodeId: nodeId, messageId: nil,
            chatMode: .companion, provider: .claude,
            verdictJSON: "{}", fallbackReason: .ok, userFeedback: nil, feedbackTs: nil
        )
        let e2 = JudgeEvent(
            id: UUID(), ts: now, nodeId: nodeId, messageId: nil,
            chatMode: .strategist, provider: .claude,
            verdictJSON: "{}", fallbackReason: .ok, userFeedback: nil, feedbackTs: nil
        )
        try store.appendJudgeEvent(e1)
        try store.appendJudgeEvent(e2)

        XCTAssertEqual(try store.latestChatMode(forNode: nodeId), .strategist)
    }

    func testLatestChatModeReturnsNilWhenNoRows() throws {
        let nodeId = UUID()
        XCTAssertNil(try store.latestChatMode(forNode: nodeId))
    }

    func testLatestChatModeIgnoresOtherNodes() throws {
        let targetId = UUID()
        let otherId = UUID()
        let target = NousNode(id: targetId, type: .conversation, title: "target")
        let other = NousNode(id: otherId, type: .conversation, title: "other")
        try store.insertNode(target)
        try store.insertNode(other)

        let now = Date()
        let unrelated = JudgeEvent(
            id: UUID(), ts: now, nodeId: otherId, messageId: nil,
            chatMode: .strategist, provider: .claude,
            verdictJSON: "{}", fallbackReason: .ok, userFeedback: nil, feedbackTs: nil
        )
        try store.appendJudgeEvent(unrelated)

        XCTAssertNil(try store.latestChatMode(forNode: targetId))
    }

    @MainActor
    func testFirstTurnPassesNilPreviousMode() async throws {
        XCTAssertNil(viewModel.activeChatMode)

        judge.nextVerdict = JudgeVerdict(
            tensionExists: false, userState: .exploring, shouldProvoke: false,
            entryId: nil, reason: "first turn", inferredMode: .companion
        )
        viewModel.inputText = "hello"
        await viewModel.send()

        XCTAssertEqual(judge.previousModeHistory.count, 1)
        XCTAssertNil(judge.previousModeHistory[0],
                     "first send() must pass previousMode: nil to the judge")
    }

    @MainActor
    func testSecondTurnPassesPriorInferredMode() async throws {
        judge.nextVerdict = JudgeVerdict(
            tensionExists: false, userState: .exploring, shouldProvoke: false,
            entryId: nil, reason: "t1", inferredMode: .strategist
        )
        viewModel.inputText = "help me think this through"
        await viewModel.send()

        judge.nextVerdict = JudgeVerdict(
            tensionExists: false, userState: .exploring, shouldProvoke: false,
            entryId: nil, reason: "t2", inferredMode: .strategist
        )
        viewModel.inputText = "continue"
        await viewModel.send()

        XCTAssertEqual(judge.previousModeHistory.count, 2)
        XCTAssertNil(judge.previousModeHistory[0])
        XCTAssertEqual(judge.previousModeHistory[1], .strategist)
    }

    @MainActor
    func testSystemPromptUsesEffectiveModeNotPriorActiveMode() async throws {
        viewModel.activeChatMode = .companion

        judge.nextVerdict = JudgeVerdict(
            tensionExists: false, userState: .deciding, shouldProvoke: false,
            entryId: nil, reason: "register shift", inferredMode: .strategist
        )
        viewModel.inputText = "break this down for me"
        await viewModel.send()

        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("STRATEGIST MODE"),
                      "assembleContext must have run with verdict.inferredMode (.strategist), not prior activeChatMode (.companion)")
        XCTAssertFalse(system.contains("COMPANION MODE"),
                       "prior mode must not leak into this turn's system prompt")
    }

    @MainActor
    func testLocalProviderFallbackKeepsActiveMode() async throws {
        let localLLM = CannedLLMService()
        let localJudge = StubJudge()
        let vectorStore = VectorStore(nodeStore: store)
        let memoryService = UserMemoryService(nodeStore: store, llmServiceProvider: { localLLM })
        let localVM = ChatViewModel(
            nodeStore: store,
            vectorStore: vectorStore,
            embeddingService: EmbeddingService(),
            graphEngine: GraphEngine(nodeStore: store, vectorStore: vectorStore),
            userMemoryService: memoryService,
            userMemoryScheduler: UserMemoryScheduler(service: memoryService),
            llmServiceProvider: { localLLM },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { CannedLLMService() },
            provocationJudgeFactory: { _ in localJudge },
            governanceTelemetry: telemetry
        )
        let convo = NousNode(type: .conversation, title: "seed", projectId: nil)
        try store.insertNode(convo)
        localVM.currentNode = convo
        localVM.activeChatMode = .strategist

        localVM.inputText = "hi"
        await localVM.send()

        XCTAssertEqual(localVM.activeChatMode, .strategist)
        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertEqual(events.last?.chatMode, .strategist)
        XCTAssertEqual(events.last?.fallbackReason, .providerLocal)
        XCTAssertEqual(localJudge.previousModeHistory.count, 0,
                       ".local should short-circuit before the judge factory is called")
    }

    @MainActor
    func testJudgeTimeoutFallbackKeepsActiveMode() async throws {
        let convo = NousNode(type: .conversation, title: "seed", projectId: nil)
        try store.insertNode(convo)
        viewModel.currentNode = convo
        viewModel.activeChatMode = .strategist
        judge.nextError = .timeout

        viewModel.inputText = "hi"
        await viewModel.send()

        XCTAssertEqual(viewModel.activeChatMode, .strategist)
        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertEqual(events.last?.chatMode, .strategist)
        XCTAssertEqual(events.last?.fallbackReason, .timeout)
    }

    @MainActor
    func testActiveChatModeUpdatedBeforeMainCall() async throws {
        viewModel.activeChatMode = .companion
        judge.nextVerdict = JudgeVerdict(
            tensionExists: false, userState: .deciding, shouldProvoke: false,
            entryId: nil, reason: "shift", inferredMode: .strategist
        )
        llm.nextError = NSError(domain: "test", code: 1)

        viewModel.inputText = "hi"
        await viewModel.send()

        XCTAssertEqual(viewModel.activeChatMode, .strategist,
                       "activeChatMode must be updated before the main LLM call so retry-without-reload has correct previousMode")
    }

    @MainActor
    func testJudgeEventAppendedBeforeMainCall() async throws {
        judge.nextVerdict = JudgeVerdict(
            tensionExists: false, userState: .exploring, shouldProvoke: false,
            entryId: nil, reason: "t", inferredMode: .companion
        )
        llm.nextError = NSError(domain: "test", code: 1)

        viewModel.inputText = "hi"
        await viewModel.send()

        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertEqual(events.count, 1, "judge_events row must persist even when main LLM call fails")
        XCTAssertEqual(events.first?.fallbackReason, .ok)
    }

    @MainActor
    func testLoadConversationHydratesFromLatestEvent() throws {
        let node = NousNode(type: .conversation, title: "t", projectId: nil)
        try store.insertNode(node)

        let event = JudgeEvent(
            id: UUID(), ts: Date(), nodeId: node.id, messageId: nil,
            chatMode: .strategist, provider: .claude,
            verdictJSON: "{}", fallbackReason: .ok, userFeedback: nil, feedbackTs: nil
        )
        try store.appendJudgeEvent(event)

        viewModel.loadConversation(node)

        XCTAssertEqual(viewModel.activeChatMode, .strategist)
    }

    @MainActor
    func testLoadConversationKeepsNilWhenNoEvents() throws {
        let node = NousNode(type: .conversation, title: "t", projectId: nil)
        try store.insertNode(node)

        // Seed something unrelated first so we know we're testing empty-for-this-node, not empty-table
        viewModel.activeChatMode = .strategist

        viewModel.loadConversation(node)

        XCTAssertNil(viewModel.activeChatMode)
    }

    @MainActor
    func testStartNewConversationResetsToNil() throws {
        viewModel.activeChatMode = .strategist
        viewModel.startNewConversation(title: "new", projectId: nil)
        XCTAssertNil(viewModel.activeChatMode)
    }

    @MainActor
    func testQuickActionOpenerUsesCompanionAndDoesNotRunJudge() async throws {
        XCTAssertNil(viewModel.activeChatMode)

        // Seed the judge with a "loud" verdict to prove it DIDN'T run
        judge.nextVerdict = JudgeVerdict(
            tensionExists: true, userState: .deciding, shouldProvoke: true,
            entryId: nil, reason: "should not run", inferredMode: .strategist
        )

        await viewModel.beginQuickActionConversation(.direction)

        // (a) assembled context used .companion
        let system = llm.receivedSystem ?? ""
        XCTAssertTrue(system.contains("COMPANION MODE"),
                      "quick-action opener must assemble with .companion")
        XCTAssertFalse(system.contains("STRATEGIST MODE"))
        // (b) no judge_events row
        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)
        XCTAssertTrue(events.isEmpty, "quick-action opener must not append judge_events")
        // (c) activeChatMode still nil
        XCTAssertNil(viewModel.activeChatMode)
        // (d) the recording stub's history stays empty (no judge.judge(...) call)
        XCTAssertTrue(judge.previousModeHistory.isEmpty)
    }
}
