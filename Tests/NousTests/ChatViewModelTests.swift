import XCTest
@testable import Nous

final class SlowStreamingLLMService: LLMService {
    private(set) var wasCancelled = false

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                continuation.yield("first ")
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    try Task.checkCancellation()
                    continuation.yield("second")
                    continuation.finish()
                } catch is CancellationError {
                    await MainActor.run {
                        self.wasCancelled = true
                    }
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }
}

final class SingleReplyLLMService: LLMService {
    let output: String

    init(output: String) {
        self.output = output
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        let output = self.output
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}

final class CapturingSingleReplyLLMService: LLMService {
    private let lock = NSLock()
    private let output: String
    private var storedReceivedSystem: String?
    private var storedReceivedMessages: [LLMMessage] = []

    var receivedSystem: String? {
        lock.withLock { storedReceivedSystem }
    }

    var receivedPromptText: String {
        lock.withLock {
            ([storedReceivedSystem ?? ""] + storedReceivedMessages.map(\.content))
                .joined(separator: "\n\n")
        }
    }

    init(output: String) {
        self.output = output
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        lock.withLock {
            storedReceivedSystem = system
            storedReceivedMessages = messages
        }
        let output = self.output
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}

final class CancellationFailingLLMService: LLMService {
    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        throw CancellationError()
    }
}

@MainActor
final class ChatViewModelTests: XCTestCase {

    private func makeScratchPadStore(nodeStore: NodeStore) -> ScratchPadStore {
        let suiteName = "ChatViewModelTests.scratchpad.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ScratchPadStore(nodeStore: nodeStore, defaults: defaults)
    }

    func testChatModeDefaultsToNil() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { nil },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )

        XCTAssertNil(vm.activeChatMode)
    }

    func testPurgePersistedThinkingFromLoadedMessagesClearsVisibleTraces() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { nil },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )
        vm.messages = [
            Message(nodeId: UUID(), role: .assistant, content: "Answer", thinkingContent: "Stored trace")
        ]

        vm.purgePersistedThinkingFromLoadedMessages()

        XCTAssertNil(vm.messages.first?.thinkingContent)
    }

    func testPurgeGeminiHistoryCachesClearsLocalEntries() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let promptCache = GeminiPromptCacheService()
        let conversationId = UUID()
        promptCache.store(
            GeminiConversationCacheEntry(
                name: "cachedContents/test",
                model: "gemini-2.5-flash",
                promptHash: "abc",
                expireTime: Date().addingTimeInterval(300)
            ),
            for: conversationId
        )

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { nil },
            currentProviderProvider: { .gemini },
            judgeLLMServiceFactory: { nil },
            geminiPromptCache: promptCache,
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )

        await vm.purgeGeminiHistoryCaches()

        XCTAssertNil(promptCache.entry(for: conversationId))
    }

    func testSendCreatesConversationInsideSelectedProject() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let scratchPadStore = await MainActor.run { makeScratchPadStore(nodeStore: nodeStore) }

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { nil },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: scratchPadStore
        )

        let project = Project(title: "Nous")
        try nodeStore.insertProject(project)

        vm.defaultProjectId = project.id
        vm.inputText = "How should memory entries work?"

        await vm.send()

        XCTAssertEqual(vm.currentNode?.projectId, project.id)
    }

    func testLocalNoProviderErrorPersistsAssistantReply() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let scratchPadStore = await MainActor.run { makeScratchPadStore(nodeStore: nodeStore) }

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { nil },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: scratchPadStore
        )

        vm.inputText = "Help me think"
        await vm.send()

        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        let storedMessages = try nodeStore.fetchMessages(nodeId: nodeId)
        let assistantMessage = try XCTUnwrap(storedMessages.last(where: { $0.role == .assistant }))

        XCTAssertEqual(assistantMessage.content, "Please configure an LLM in Settings.")
        XCTAssertEqual(vm.messages.last?.content, assistantMessage.content)
    }

    func testRegenerateLatestAssistantReplacesReplyWithoutDuplicatingUser() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let scratchPadStore = await MainActor.run { makeScratchPadStore(nodeStore: nodeStore) }
        var llm = SingleReplyLLMService(output: "first answer")

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { llm },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: scratchPadStore
        )

        vm.inputText = "Help me think"
        await vm.send()

        let firstAssistant = try XCTUnwrap(vm.messages.last)
        XCTAssertTrue(vm.canRegenerateAssistantMessage(firstAssistant.id))

        llm = SingleReplyLLMService(output: "second answer")
        await vm.regenerateLatestAssistant()

        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        let storedMessages = try nodeStore.fetchMessages(nodeId: nodeId)
        let storedNode = try XCTUnwrap(nodeStore.fetchNode(id: nodeId))

        XCTAssertEqual(vm.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(storedMessages.map(\.role), [.user, .assistant])
        XCTAssertEqual(storedMessages.last?.content, "second answer")
        XCTAssertFalse(storedMessages.contains { $0.content == "first answer" })
        XCTAssertFalse(storedNode.content.contains("first answer"))
        XCTAssertTrue(storedNode.content.contains("second answer"))
    }

    func testSendSurfacesPlanningFailureAsVisibleAssistantMessage() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let scratchPadStore = await MainActor.run { makeScratchPadStore(nodeStore: nodeStore) }

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { SingleReplyLLMService(output: "unused") },
            currentProviderProvider: { .openrouter },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: scratchPadStore
        )

        vm.currentNode = NousNode(type: .conversation, title: "Ghost Chat")
        vm.inputText = "Why no reply?"

        await vm.send()

        let assistantMessage = try XCTUnwrap(vm.messages.last)
        XCTAssertEqual(assistantMessage.role, .assistant)
        XCTAssertTrue(assistantMessage.content.hasPrefix("Error:"))
        XCTAssertTrue(vm.currentResponse.isEmpty)
        XCTAssertFalse(vm.isGenerating)
    }

    func testUnexpectedCancellationPersistsVisibleAssistantError() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let scratchPadStore = await MainActor.run { makeScratchPadStore(nodeStore: nodeStore) }

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { CancellationFailingLLMService() },
            currentProviderProvider: { .openrouter },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: scratchPadStore
        )

        vm.inputText = "Please reply"
        await vm.send()

        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        let storedMessages = try nodeStore.fetchMessages(nodeId: nodeId)
        let assistantMessage = try XCTUnwrap(storedMessages.last(where: { $0.role == .assistant }))

        XCTAssertEqual(
            assistantMessage.content,
            "Error: The reply was interrupted before it finished. Please try again."
        )
        XCTAssertEqual(vm.messages.last?.content, assistantMessage.content)
        XCTAssertTrue(vm.currentResponse.isEmpty)
        XCTAssertFalse(vm.isGenerating)
    }

    func testQuickActionConversationUsesSelectedProject() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let scratchPadStore = await MainActor.run { makeScratchPadStore(nodeStore: nodeStore) }

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { nil },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: scratchPadStore
        )

        let project = Project(title: "Memory Project")
        try nodeStore.insertProject(project)
        vm.defaultProjectId = project.id

        await vm.beginQuickActionConversation(.direction)

        XCTAssertEqual(vm.currentNode?.projectId, project.id)
    }

    func testQuickActionOpeningUsesTasteSkillsAndSkipsModeSkeleton() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let skillStore = SkillStore(nodeStore: nodeStore)
        try skillStore.insertSkill(makeSkill(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            name: "opening-direction-skeleton",
            kind: .mode,
            content: "OPENING MODE SKELETON SHOULD NOT APPEAR"
        ))
        try skillStore.insertSkill(makeSkill(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            name: "opening-taste",
            kind: .always,
            content: "OPENING TASTE SKILL SHOULD APPEAR"
        ))
        let llm = CapturingSingleReplyLLMService(output: "Opening reply")

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { llm },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            skillStore: skillStore,
            skillMatcher: SkillMatcher(),
            skillTracker: SkillTracker(store: skillStore),
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )

        await vm.beginQuickActionConversation(.direction)

        let promptText = llm.receivedPromptText
        XCTAssertTrue(promptText.contains("OPENING TASTE SKILL SHOULD APPEAR"))
        XCTAssertFalse(promptText.contains("OPENING MODE SKELETON SHOULD NOT APPEAR"))
        XCTAssertTrue(vm.lastPromptGovernanceTrace?.promptLayers.contains("quick_action_addendum") == true)
    }

    func testQuickActionConversationPromotesHiddenChatTitle() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let llm = SingleReplyLLMService(output: """
        我想先听你讲多少少。

        <chat_title>搬去纽约定Austin</chat_title>
        """)

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { llm },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )

        await vm.beginQuickActionConversation(.direction)

        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        let storedNode = try XCTUnwrap(nodeStore.fetchNode(id: nodeId))
        let storedMessages = try nodeStore.fetchMessages(nodeId: nodeId)
        let assistant = try XCTUnwrap(storedMessages.last)

        XCTAssertEqual(vm.currentNode?.title, "搬去纽约定Austin")
        XCTAssertEqual(storedNode.title, "搬去纽约定Austin")
        XCTAssertEqual(assistant.content, "我想先听你讲多少少。")
        XCTAssertFalse(assistant.content.contains("<chat_title>"))
    }

    private func makeSkill(
        id: UUID,
        name: String,
        kind: SkillTrigger.Kind,
        content: String
    ) -> Skill {
        Skill(
            id: id,
            userId: "alex",
            payload: SkillPayload(
                payloadVersion: 1,
                name: name,
                source: .alex,
                trigger: SkillTrigger(
                    kind: kind,
                    modes: [.direction],
                    priority: 70
                ),
                action: SkillAction(kind: .promptFragment, content: content)
            ),
            state: .active,
            firedCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastModifiedAt: Date(timeIntervalSince1970: 1_000),
            lastFiredAt: nil
        )
    }

    @MainActor
    func testStopGeneratingCancelsMainResponseWithoutPersistingAssistant() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let slowLLM = SlowStreamingLLMService()

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { slowLLM },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )

        vm.inputText = "Help me think"
        let sendTask = Task { await vm.send() }
        try await Task.sleep(nanoseconds: 100_000_000)

        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        XCTAssertTrue(vm.isGenerating)

        vm.stopGenerating()
        await sendTask.value

        let storedMessages = try nodeStore.fetchMessages(nodeId: nodeId)
        XCTAssertTrue(slowLLM.wasCancelled)
        XCTAssertFalse(vm.isGenerating)
        XCTAssertTrue(storedMessages.contains { $0.role == .user })
        XCTAssertFalse(storedMessages.contains { $0.role == .assistant })
        XCTAssertFalse(vm.currentResponse.isEmpty)
    }

    @MainActor
    func testLoadConversationCancelsMainResponseWithoutCrossChatLeak() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let slowLLM = SlowStreamingLLMService()

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { slowLLM },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )

        vm.inputText = "first"
        let sendTask = Task { await vm.send() }
        try await Task.sleep(nanoseconds: 100_000_000)

        let originalNodeId = try XCTUnwrap(vm.currentNode?.id)
        let otherNode = NousNode(type: .conversation, title: "Other conversation")
        try nodeStore.insertNode(otherNode)

        vm.loadConversation(otherNode)
        await sendTask.value

        let originalMessages = try nodeStore.fetchMessages(nodeId: originalNodeId)
        XCTAssertFalse(vm.isGenerating)
        XCTAssertEqual(vm.currentNode?.id, otherNode.id)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertEqual(originalMessages.filter { $0.role == .assistant }.count, 0)
        XCTAssertEqual(originalMessages.filter { $0.role == .user }.count, 1)
    }

    @MainActor
    func testNoProviderErrorPersistsSnapshotAndJudgeEventMessageLink() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let suiteName = "ChatViewModelTests.no-provider.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let telemetry = GovernanceTelemetryStore(defaults: defaults, nodeStore: nodeStore)

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { nil },
            currentProviderProvider: { .claude },
            judgeLLMServiceFactory: { nil },
            governanceTelemetry: telemetry,
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )

        vm.inputText = "Need help"
        await vm.send()

        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        let assistantMessage = try XCTUnwrap(vm.messages.last)
        let storedNode = try XCTUnwrap(nodeStore.fetchNode(id: nodeId))
        let events = telemetry.recentJudgeEvents(limit: 5, filter: .none)

        XCTAssertEqual(assistantMessage.role, .assistant)
        XCTAssertEqual(assistantMessage.content, "Please configure an LLM in Settings.")
        XCTAssertTrue(storedNode.content.contains(assistantMessage.content))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.messageId, assistantMessage.id)
    }

    func testGovernanceTelemetryRecordsPromptTraceWithoutSafetyMissWhenSafetyInvoked() throws {
        let suiteName = "ChatViewModelTests.governance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let telemetry = GovernanceTelemetryStore(defaults: defaults)

        telemetry.recordPromptTrace(
            PromptGovernanceTrace(
                promptLayers: ["anchor", "core_safety_policy", "global_memory", "high_risk_safety_mode"],
                evidenceAttached: false,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: true
            )
        )

        XCTAssertEqual(telemetry.value(for: .memoryUsefulness), 1)
        XCTAssertEqual(telemetry.value(for: .safetyMissRate), 0)
        XCTAssertEqual(telemetry.lastPromptTrace?.safetyPolicyInvoked, true)
    }

    func testGovernanceTelemetryAggregatesGeminiCacheUsage() throws {
        let suiteName = "ChatViewModelTests.gemini-cache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let telemetry = GovernanceTelemetryStore(defaults: defaults)

        telemetry.recordGeminiUsage(
            GeminiUsageMetadata(
                promptTokenCount: 2000,
                cachedContentTokenCount: 1500,
                candidatesTokenCount: 200,
                thoughtsTokenCount: 40,
                totalTokenCount: 2200
            ),
            at: Date(timeIntervalSince1970: 100)
        )
        telemetry.recordGeminiUsage(
            GeminiUsageMetadata(
                promptTokenCount: 1200,
                cachedContentTokenCount: 600,
                candidatesTokenCount: 150,
                thoughtsTokenCount: nil,
                totalTokenCount: 1350
            ),
            at: Date(timeIntervalSince1970: 200)
        )

        let summary = try XCTUnwrap(telemetry.geminiCacheSummary)
        let last = try XCTUnwrap(summary.lastSnapshot)

        XCTAssertEqual(summary.requestCount, 2)
        XCTAssertEqual(summary.totalPromptTokens, 3200)
        XCTAssertEqual(summary.totalCachedTokens, 2100)
        XCTAssertEqual(last.usage.promptTokenCount, 1200)
        XCTAssertEqual(last.usage.cachedContentTokenCount, 600)
        XCTAssertEqual(Int((summary.cacheHitRate! * 100).rounded()), 66)
    }

    func testGovernanceTraceIncludesSummaryOutputPolicyLayer() {
        let trace = ChatViewModel.governanceTrace(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )
        XCTAssertTrue(
            trace.promptLayers.contains("stoic_grounding_policy"),
            "Expected stable layer 'stoic_grounding_policy' in \(trace.promptLayers)"
        )
        XCTAssertTrue(
            trace.promptLayers.contains("summary_output_policy"),
            "Expected stable layer 'summary_output_policy' in \(trace.promptLayers)"
        )
        XCTAssertTrue(
            trace.promptLayers.contains("conversation_title_output_policy"),
            "Expected stable layer 'conversation_title_output_policy' in \(trace.promptLayers)"
        )
    }

    func testAssembleContextStableIncludesSummaryInstruction() {
        let slice = ChatViewModel.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )
        XCTAssertTrue(slice.stable.contains("<summary>"), "Stable system prompt must mention <summary> tag.")
        XCTAssertTrue(slice.stable.contains("<chat_title>"), "Stable system prompt must mention <chat_title> tag.")
        XCTAssertTrue(
            slice.stable.contains("STOIC GROUNDING POLICY"),
            "Stable system prompt must carry the explicit Stoic grounding layer."
        )
        XCTAssertTrue(
            slice.stable.contains("Do not sound like a philosophy book"),
            "Stoic grounding must stay a judgment rule, not a surface voice gimmick."
        )
        // The policy must be language-adaptive, not hard-wired to Mandarin.
        XCTAssertTrue(
            slice.stable.contains("match the conversation language"),
            "Stable system prompt must tell the model to match the conversation language."
        )
        // It should still carry concrete header vocab for each supported language so the model
        // knows what to emit when the conversation is in that language.
        XCTAssertTrue(slice.stable.contains("下一步"), "Should include Chinese header vocabulary.")
        XCTAssertTrue(slice.stable.contains("Next steps"), "Should include English header vocabulary.")
        XCTAssertTrue(
            slice.stable.contains("Do not translate Cantonese into Mandarin"),
            "Stable system prompt must preserve Cantonese titles instead of flattening them into Mandarin."
        )
    }

    func testUserMessageContentCapsImageAttachmentsAtFive() {
        let imageAttachments = (1...6).map {
            AttachedFileContext(name: "Photo \($0).jpeg", extractedText: "image text \($0)")
        }

        let content = TurnPlanner.userMessageContent(
            inputText: "Look at these",
            attachments: imageAttachments
        )

        XCTAssertTrue(content.contains("Photo 1.jpeg"))
        XCTAssertTrue(content.contains("Photo 5.jpeg"))
        XCTAssertFalse(content.contains("Photo 6.jpeg"))
    }

    func testImageAttachmentCapDoesNotDropNonImageFiles() {
        let imageAttachments = (1...6).map {
            AttachedFileContext(name: "Photo \($0).jpeg", extractedText: "image text \($0)")
        }
        let document = AttachedFileContext(name: "context.pdf", extractedText: "document text")

        let content = TurnPlanner.userMessageContent(
            inputText: "Use these",
            attachments: imageAttachments + [document]
        )

        XCTAssertFalse(content.contains("Photo 6.jpeg"))
        XCTAssertTrue(content.contains("context.pdf"))
    }

    func testDroppedImageContextsIgnoreNonImageFiles() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nous-drop-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let imageURL = folder.appendingPathComponent("dragged.png")
        let textURL = folder.appendingPathComponent("notes.txt")
        try Data("not real image bytes".utf8).write(to: imageURL)
        try Data("plain text".utf8).write(to: textURL)

        let contexts = AttachmentExtractor.imageFileContexts(from: [imageURL, textURL])

        XCTAssertEqual(contexts.map(\.name), ["dragged.png"])
    }

    @MainActor
    func testSendPromotesHiddenChatTitleAndStripsItFromStoredAssistantMessage() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let llm = SingleReplyLLMService(output: """
        我会直接答你。

        <chat_title>AI 时代仲要唔要生细路</chat_title>
        """)

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { llm },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )

        vm.inputText = "其实你觉得系未来 AI 时代系咪生孩子真系冇有嗰么必要？"
        await vm.send()

        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        let storedNode = try XCTUnwrap(nodeStore.fetchNode(id: nodeId))
        let storedMessages = try nodeStore.fetchMessages(nodeId: nodeId)
        let assistant = try XCTUnwrap(storedMessages.last)

        XCTAssertEqual(vm.currentNode?.title, "AI 时代仲要唔要生细路")
        XCTAssertEqual(storedNode.title, "AI 时代仲要唔要生细路")
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.content, "我会直接答你。")
        XCTAssertFalse(assistant.content.contains("<chat_title>"))
    }

    @MainActor
    func testIngestsSummaryFromAssistantReply() {
        let suiteName = "ChatViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let nodeStore = try! NodeStore(path: ":memory:")
        let store = ScratchPadStore(nodeStore: nodeStore, defaults: defaults)

        let raw = """
        搞掂。
        <summary>
        # 今次倾咗乜

        ## 问题
        Alex 想搞清楚 Notion 点走。

        ## 思考
        倾咗 AI agent 嘅取舍。

        ## 结论
        唔加。

        ## 下一步
        - 观察三个月
        </summary>
        """
        let conversationId = UUID()
        try? nodeStore.insertNode(NousNode(id: conversationId, type: .conversation, title: "Scratch Summary"))
        store.activate(conversationId: conversationId)
        let msg = Message(nodeId: conversationId, role: .assistant, content: raw)
        store.ingestAssistantMessage(
            content: msg.content,
            sourceMessageId: msg.id,
            conversationId: conversationId
        )

        XCTAssertNotNil(store.latestSummary)
        XCTAssertTrue(store.latestSummary!.markdown.hasPrefix("# 今次倾咗乜"))
        XCTAssertEqual(store.latestSummary!.sourceMessageId, msg.id)
    }
}
