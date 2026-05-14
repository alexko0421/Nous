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

@MainActor
private func waitUntilOnMainActor(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @MainActor @escaping () -> Bool
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
            XCTFail("Timed out waiting for condition.")
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

final class ChatStreamingPresentationTests: XCTestCase {
    func testKeepsThinkingExpandedWhileAnswerTextStreams() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let presentation = StreamingAssistantPresentation(
            isGenerating: true,
            currentThinking: "First, identify the actual constraint.",
            currentThinkingStartedAt: startedAt,
            currentResponse: "The short answer is",
            currentAgentTraceIsEmpty: true
        )

        XCTAssertTrue(presentation.showsAssistantDraft)
        XCTAssertEqual(presentation.draftThinkingContent, "First, identify the actual constraint.")
        XCTAssertEqual(presentation.draftThinkingStartedAt, startedAt)
        XCTAssertTrue(presentation.isDraftThinkingStreaming)
    }

    func testThinkingAccordionTitleShowsElapsedSecondsWhileStreaming() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let now = startedAt.addingTimeInterval(7.4)

        let title = ThinkingAccordion.titleText(
            isStreaming: true,
            startedAt: startedAt,
            now: now
        )

        XCTAssertEqual(title, "Thinking for 7s")
    }

    func testShowsThinkingPillWhenAgentTraceArrivesBeforeAnswerText() {
        let presentation = StreamingAssistantPresentation(
            isGenerating: true,
            currentThinking: "",
            currentThinkingStartedAt: Date(timeIntervalSince1970: 100),
            currentResponse: "",
            currentAgentTraceIsEmpty: false
        )

        XCTAssertTrue(presentation.showsPendingThinking)
        XCTAssertFalse(presentation.pendingThinkingContent.isEmpty)
    }

    func testShowsThinkingPillWhileAnswerStreamsWithoutVisibleReasoning() {
        let presentation = StreamingAssistantPresentation(
            isGenerating: true,
            currentThinking: "",
            currentThinkingStartedAt: Date(timeIntervalSince1970: 100),
            currentResponse: "Here is the answer",
            currentAgentTraceIsEmpty: true
        )

        XCTAssertTrue(presentation.showsAssistantDraft)
        XCTAssertFalse(presentation.draftThinkingContent?.isEmpty ?? true)
        XCTAssertTrue(presentation.isDraftThinkingStreaming)
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
    private var didCapturePrompt = false
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

    var generateCallCount: Int {
        lock.withLock { didCapturePrompt ? 1 : 0 }
    }

    init(output: String) {
        self.output = output
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        lock.withLock {
            if !didCapturePrompt {
                didCapturePrompt = true
                storedReceivedSystem = system
                storedReceivedMessages = messages
            }
        }
        let output = self.output
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}

final class RecordingReplyLLMService: LLMService {
    private let lock = NSLock()
    private let output: String
    private var storedPromptTexts: [String] = []

    var promptTexts: [String] {
        lock.withLock { storedPromptTexts }
    }

    init(output: String) {
        self.output = output
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        lock.withLock {
            storedPromptTexts.append(
                ([system ?? ""] + messages.map(\.content))
                    .joined(separator: "\n\n")
            )
        }
        let output = self.output
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}

private final class SequencedSourceBriefingLLMService: LLMService {
    private let lock = NSLock()
    private var outputs: [String]

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        let output = lock.withLock {
            if outputs.isEmpty { return "{}" }
            return outputs.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}

private final class DynamicSourceBriefingLLMService: LLMService {
    private let lock = NSLock()
    private var headlines: [String]

    init(headlines: [String]) {
        self.headlines = headlines
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        let prompt = messages.map(\.content).joined(separator: "\n\n")
        let sourceId = Self.firstUUID(in: prompt) ?? UUID()
        let headline = lock.withLock {
            if headlines.isEmpty { return "Source brief" }
            return headlines.removeFirst()
        }
        let output = """
        {
          "title": "Document source brief",
          "items": [
            {
              "source_node_id": "\(sourceId.uuidString)",
              "headline": "\(headline)",
              "what_changed": "Supplier renegotiation improved gross margin after pricing changed.",
              "why_it_matters": "It changes whether the business is still margin-constrained.",
              "alex_relevance": "Relevant to Alex's quality filter.",
              "tension_or_risk": "This could be a temporary one-quarter effect.",
              "suggested_next_action": "Check whether the next quarter keeps the same margin level.",
              "evidence": "supplier renegotiation improved gross margin",
              "confidence": 0.78
            }
          ]
        }
        """
        return AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }

    private static func firstUUID(in text: String) -> UUID? {
        let pattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return UUID(uuidString: String(text[range]))
    }
}

final class CancellationFailingLLMService: LLMService {
    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        throw CancellationError()
    }
}

private final class TimedStreamingLLMService: LLMService, ThinkingDeltaConfigurableLLMService, LLMModelIdentifying {
    private let lock = NSLock()
    private let chunks: [String]
    let modelIdentifier = "timed-test-model"

    private var storedThinkingHandlerInstallCount = 0

    var thinkingHandlerInstallCount: Int {
        lock.withLock { storedThinkingHandlerInstallCount }
    }

    init(chunks: [String]) {
        self.chunks = chunks
    }

    func withThinkingDeltaHandler(_ handler: @escaping ThinkingDeltaHandler) -> any LLMService {
        lock.withLock {
            storedThinkingHandlerInstallCount += 1
        }
        return self
    }

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        let chunks = self.chunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private final class SequenceDateProvider {
    private let lock = NSLock()
    private var offsets: [TimeInterval]

    init(_ offsets: [TimeInterval]) {
        self.offsets = offsets
    }

    func next() -> Date {
        lock.withLock {
            Date(timeIntervalSince1970: offsets.isEmpty ? 0 : offsets.removeFirst())
        }
    }
}

private struct ChatViewModelNoOpTurnEventSink: TurnEventSink {
    func emit(_ envelope: TurnEventEnvelope) async {}
}

@MainActor
final class ChatViewModelTests: XCTestCase {

    private func makeScratchPadStore(nodeStore: NodeStore) -> ScratchPadStore {
        let suiteName = "ChatViewModelTests.scratchpad.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ScratchPadStore(nodeStore: nodeStore, defaults: defaults)
    }

    private static func isDocumentSourcePrompt(_ prompt: String) -> Bool {
        prompt.contains("SOURCE MATERIAL") &&
            prompt.contains("report.txt") &&
            prompt.contains("source-only late section")
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

    func testStartBlankConversationClearsTurnStateWithoutCreatingANewNode() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let scratchPadStore = makeScratchPadStore(nodeStore: nodeStore)

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
        let node = NousNode(type: .conversation, title: "Arc 1")
        try nodeStore.insertNode(node)
        let message = Message(nodeId: node.id, role: .user, content: "old probe")

        vm.currentNode = node
        vm.messages = [message]
        vm.inputText = "draft"
        vm.currentResponse = "partial"
        vm.currentThinking = "thinking"
        vm.currentThinkingStartedAt = Date()
        vm.currentAgentTrace = [
            AgentTraceRecord(kind: .toolCall, title: "Old tool", detail: "old trace")
        ]
        vm.didHitBudgetExhaustion = true
        vm.citations = [SearchResult(node: node, similarity: 0.9)]
        vm.activeQuickActionMode = .plan
        vm.activeChatMode = .strategist
        vm.lastPromptGovernanceTrace = PromptGovernanceTrace(
            promptLayers: ["recent_conversations"],
            evidenceAttached: true,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false
        )
        scratchPadStore.activate(conversationId: node.id)

        vm.startBlankConversation()

        XCTAssertNil(vm.currentNode)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertTrue(vm.inputText.isEmpty)
        XCTAssertTrue(vm.currentResponse.isEmpty)
        XCTAssertTrue(vm.currentThinking.isEmpty)
        XCTAssertNil(vm.currentThinkingStartedAt)
        XCTAssertTrue(vm.currentAgentTrace.isEmpty)
        XCTAssertFalse(vm.didHitBudgetExhaustion)
        XCTAssertTrue(vm.citations.isEmpty)
        XCTAssertNil(vm.activeQuickActionMode)
        XCTAssertNil(vm.activeChatMode)
        XCTAssertNil(vm.lastPromptGovernanceTrace)
        XCTAssertNil(scratchPadStore.activeConversationId)
        XCTAssertEqual(try nodeStore.fetchAllNodes().map(\.id), [node.id])
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
        let defaultsSuiteName = "ChatViewModelTests.regenerateTelemetry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let telemetry = GovernanceTelemetryStore(defaults: defaults, nodeStore: nodeStore)
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
            governanceTelemetry: telemetry,
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
        XCTAssertEqual(telemetry.behaviorEvalSummary.retryCount, 1)
        XCTAssertEqual(telemetry.behaviorEvalSummary.deleteCount, 0)
    }

    func testRegenerateLatestAssistantKeepsDocumentSourceMaterial() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let scratchPadStore = await MainActor.run { makeScratchPadStore(nodeStore: nodeStore) }
        let llm = RecordingReplyLLMService(output: "answer")

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

        vm.inputText = "Connect this report"
        await vm.send(attachments: [
            AttachedFileContext(
                name: "report.txt",
                extractedText: "Report preview",
                sourceText: "Full report says the source-only late section connects to runway decisions."
            )
        ])
        XCTAssertEqual(try nodeStore.fetchAllNodes().filter { $0.type == .source }.count, 1)
        let sourcePromptCountAfterFirstSend = llm.promptTexts.filter(Self.isDocumentSourcePrompt).count

        await vm.regenerateLatestAssistant()

        let sourcePromptCountAfterRetry = llm.promptTexts.filter(Self.isDocumentSourcePrompt).count
        XCTAssertEqual(sourcePromptCountAfterFirstSend, 1)
        XCTAssertEqual(sourcePromptCountAfterRetry, 2)
    }

    func testSendingDocumentSourcePersistsAndReloadsSourceBriefing() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let briefingLLM = DynamicSourceBriefingLLMService(headlines: ["Supplier margin changed"])
        let sourceBriefingService = SourceBriefingService(llmServiceProvider: { briefingLLM })
        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            sourceBriefingService: sourceBriefingService,
            llmServiceProvider: { SingleReplyLLMService(output: "I connected the source.") },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )

        vm.inputText = "Analyze this report"
        await vm.send(attachments: [
            AttachedFileContext(
                name: "report.txt",
                extractedText: "Report preview",
                sourceText: "Full report says supplier renegotiation improved gross margin after pricing changed."
            )
        ])

        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        let userMessage = try XCTUnwrap(try nodeStore.fetchMessages(nodeId: nodeId).first { $0.role == .user })

        XCTAssertEqual(vm.sourceBriefing(for: userMessage)?.items.first?.headline, "Supplier margin changed")

        let reloadedVM = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { SingleReplyLLMService(output: "I connected the source.") },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )
        let reloadedNode = try XCTUnwrap(nodeStore.fetchNode(id: nodeId))
        reloadedVM.loadConversation(reloadedNode)

        XCTAssertEqual(reloadedVM.sourceBriefing(for: userMessage)?.items.first?.headline, "Supplier margin changed")
    }

    func testSourceBriefingGenerationFailureDoesNotBlockAssistantResponse() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let sourceBriefingService = SourceBriefingService(llmServiceProvider: {
            SequencedSourceBriefingLLMService(outputs: ["not json"])
        })
        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            sourceBriefingService: sourceBriefingService,
            llmServiceProvider: { SingleReplyLLMService(output: "Assistant still answered.") },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )

        vm.inputText = "Analyze this report"
        await vm.send(attachments: [
            AttachedFileContext(
                name: "report.txt",
                extractedText: "Report preview",
                sourceText: "Full report says supplier renegotiation improved gross margin after pricing changed."
            )
        ])

        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        let messages = try nodeStore.fetchMessages(nodeId: nodeId)
        let userMessage = try XCTUnwrap(messages.first { $0.role == .user })
        XCTAssertEqual(messages.last?.content, "Assistant still answered.")
        XCTAssertNil(vm.sourceBriefing(for: userMessage))
    }

    func testRegenerateLatestAssistantReplacesSourceBriefingForUserMessage() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let briefingLLM = DynamicSourceBriefingLLMService(headlines: [
            "Supplier margin first",
            "Supplier margin second"
        ])
        let sourceBriefingService = SourceBriefingService(llmServiceProvider: { briefingLLM })
        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            sourceBriefingService: sourceBriefingService,
            llmServiceProvider: { SingleReplyLLMService(output: "answer") },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )

        vm.inputText = "Connect this report"
        await vm.send(attachments: [
            AttachedFileContext(
                name: "report.txt",
                extractedText: "Report preview",
                sourceText: "Full report says supplier renegotiation improved gross margin after pricing changed."
            )
        ])

        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        let userMessage = try XCTUnwrap(try nodeStore.fetchMessages(nodeId: nodeId).first { $0.role == .user })

        XCTAssertEqual(vm.sourceBriefing(for: userMessage)?.items.first?.headline, "Supplier margin first")

        await vm.regenerateLatestAssistant()
        XCTAssertEqual(vm.sourceBriefing(for: userMessage)?.items.first?.headline, "Supplier margin second")
    }

    func testActiveSourceDiscussionContextScopesNextTurnWithoutAutoSending() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let llm = RecordingReplyLLMService(output: "answer")
        let sourceNode = NousNode(
            type: .source,
            title: "Swift Concurrency Lesson",
            content: "00:00 First concept\n00:12 Second concept",
            emoji: "▶",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try nodeStore.insertSource(
            node: sourceNode,
            metadata: SourceMetadata(
                nodeId: sourceNode.id,
                kind: .web,
                originalURL: "https://youtu.be/dQw4w9WgXcQ",
                originalFilename: nil,
                contentHash: "youtube-context-test",
                ingestedAt: Date(timeIntervalSince1970: 1),
                extractionStatus: .ready
            ),
            chunks: [
                SourceChunk(
                    sourceNodeId: sourceNode.id,
                    ordinal: 0,
                    text: "00:00 First concept\n00:12 Second concept",
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            ]
        )
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

        vm.activateSourceDiscussion(
            SourceDiscussionContext(
                sourceNodeId: sourceNode.id,
                title: "Swift Concurrency Lesson",
                sourceURL: "https://youtu.be/dQw4w9WgXcQ",
                startTime: 0,
                endTime: 12,
                summaryTitle: "Opening idea",
                summary: "Explains the first concept.",
                transcriptExcerpt: "00:00 First concept"
            )
        )

        XCTAssertNotNil(vm.activeSourceDiscussionContext)
        XCTAssertNil(vm.currentNode)

        vm.inputText = "What is this section really saying?"
        await vm.send()

        let prompt = try XCTUnwrap(
            llm.promptTexts.first { prompt in
                prompt.contains("SOURCE MATERIAL") &&
                    prompt.contains("Opening idea")
            }
        )
        XCTAssertTrue(prompt.contains("SOURCE MATERIAL"))
        XCTAssertTrue(prompt.contains("Swift Concurrency Lesson"))
        XCTAssertTrue(prompt.contains("Opening idea"))
        XCTAssertTrue(prompt.contains("Explains the first concept."))
        XCTAssertTrue(prompt.contains("00:00 First concept"))
        XCTAssertNotNil(vm.activeSourceDiscussionContext)
        XCTAssertEqual(vm.activeSourceDiscussionContext?.summaryTitle, "Opening idea")
    }

    func testVagueChineseDemonstrativeStillEngagesPinnedSection() async throws {
        // Reproduces the screenshot bug: Alex clicks a YouTube section and types
        // a fragmentary "呢個 topic 我好感興趣" message. The section content
        // must reach the prompt AND the model must be told that demonstratives
        // refer to the pinned section so it doesn't ask "which topic?".
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let llm = RecordingReplyLLMService(output: "answer")
        let sourceNode = NousNode(
            type: .source,
            title: "Kai Trump on Donald Trump's 3rd Term",
            content: "10:25 Secret Service shadowing\n11:32 Dating challenges",
            emoji: "▶",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try nodeStore.insertSource(
            node: sourceNode,
            metadata: SourceMetadata(
                nodeId: sourceNode.id,
                kind: .youtube,
                originalURL: "https://www.youtube.com/watch?v=prQ7Mw_YPEE",
                originalFilename: nil,
                contentHash: "kai-trump-pinned-section",
                ingestedAt: Date(timeIntervalSince1970: 1),
                extractionStatus: .ready,
                evidenceLevel: .transcriptBacked
            ),
            chunks: [
                SourceChunk(
                    sourceNodeId: sourceNode.id,
                    ordinal: 0,
                    text: "10:25 Secret Service shadowing\n11:32 Dating challenges",
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            ]
        )
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

        vm.activateSourceDiscussion(
            SourceDiscussionContext(
                sourceNodeId: sourceNode.id,
                title: "Kai Trump on Donald Trump's 3rd Term",
                sourceURL: "https://www.youtube.com/watch?v=prQ7Mw_YPEE",
                startTime: 625,
                endTime: 718,
                summaryTitle: "Life with Secret Service",
                summary: "Kai shares the reality of having Secret Service protection.",
                transcriptExcerpt: "10:25 Secret Service shadowing",
                evidenceLevel: .transcriptBacked
            )
        )

        vm.inputText = "我想問一下，呢個 topic 我好感興趣"
        await vm.send()

        let prompt = try XCTUnwrap(
            llm.promptTexts.first { prompt in
                prompt.contains("SOURCE MATERIAL") &&
                    prompt.contains("Life with Secret Service")
            }
        )

        // The pinned-section cue must be lifted to a one-liner the model
        // cannot miss, alongside the existing rule changes that explicitly
        // forbid asking "which topic" while source material is attached.
        XCTAssertTrue(prompt.contains("Alex pinned this specific section"))
        XCTAssertTrue(prompt.contains("Life with Secret Service"))
        XCTAssertTrue(prompt.contains("呢個"))
        XCTAssertTrue(prompt.contains("Never reply with \"which topic"))
    }

    func testSentSourceDiscussionMaterialSurvivesReloadWithSelectedSectionPayload() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let llm = RecordingReplyLLMService(output: "answer")
        let sourceNode = NousNode(
            type: .source,
            title: "How to Start a Cult",
            content: "00:00 Unselected opening transcript.\n00:18 Selected leader-role section.",
            emoji: "▶",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        try nodeStore.insertSource(
            node: sourceNode,
            metadata: SourceMetadata(
                nodeId: sourceNode.id,
                kind: .youtube,
                originalURL: "https://www.youtube.com/watch?v=OQ0OOzOwsJY",
                originalFilename: nil,
                contentHash: "youtube-selected-chat-section",
                ingestedAt: Date(timeIntervalSince1970: 1),
                extractionStatus: .ready,
                evidenceLevel: .transcriptBacked
            ),
            chunks: [
                SourceChunk(
                    sourceNodeId: sourceNode.id,
                    ordinal: 0,
                    text: "00:00 Unselected opening transcript.",
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                SourceChunk(
                    sourceNodeId: sourceNode.id,
                    ordinal: 1,
                    text: "00:18 Source-wide leader role transcript.",
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            ]
        )
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

        vm.activateSourceDiscussion(
            SourceDiscussionContext(
                sourceNodeId: sourceNode.id,
                title: "How to Start a Cult",
                sourceURL: "https://www.youtube.com/watch?v=OQ0OOzOwsJY",
                startTime: 18,
                endTime: 48,
                summaryTitle: "Leader role",
                summary: "Explains why the leader creates the initial shared worldview.",
                transcriptExcerpt: "00:18 Selected leader-role section.",
                evidenceLevel: .transcriptBacked
            )
        )

        vm.inputText = "呢段讲咩"
        await vm.send()

        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        let userMessage = try XCTUnwrap(try nodeStore.fetchMessages(nodeId: nodeId).first { $0.role == .user })
        let sentMaterials = vm.sourceMaterials(for: userMessage)
        XCTAssertEqual(sentMaterials.count, 1)
        XCTAssertTrue(sentMaterials.first?.chunks.first?.text.contains("Leader role") == true)
        XCTAssertTrue(sentMaterials.first?.chunks.first?.text.contains("Selected leader-role section") == true)
        XCTAssertFalse(sentMaterials.first?.chunks.first?.text.contains("Unselected opening transcript") == true)

        let reloadedVM = ChatViewModel(
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
        let reloadedNode = try XCTUnwrap(nodeStore.fetchNode(id: nodeId))
        reloadedVM.loadConversation(reloadedNode)

        let reloadedMaterials = reloadedVM.sourceMaterials(for: userMessage)
        XCTAssertEqual(reloadedMaterials.count, 1)
        XCTAssertTrue(reloadedMaterials.first?.chunks.first?.text.contains("Leader role") == true)
        XCTAssertTrue(reloadedMaterials.first?.chunks.first?.text.contains("Selected leader-role section") == true)
        XCTAssertFalse(reloadedMaterials.first?.chunks.first?.text.contains("Unselected opening transcript") == true)
    }

    func testKeepsSourceDiscussionContextWhenMessageSourcePersistenceFails() async throws {
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
            llmServiceProvider: { SingleReplyLLMService(output: "answer") },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )
        let context = SourceDiscussionContext(
            sourceNodeId: UUID(),
            title: "Missing source node",
            sourceURL: "https://www.youtube.com/watch?v=missing",
            startTime: 18,
            endTime: 48,
            summaryTitle: "Leader role",
            summary: "Explains why the leader creates the initial shared worldview.",
            transcriptExcerpt: "00:18 Selected leader-role section.",
            evidenceLevel: .transcriptBacked
        )

        vm.activateSourceDiscussion(context)
        vm.inputText = "呢段讲咩"
        await vm.send()

        XCTAssertEqual(vm.activeSourceDiscussionContext, context)
        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        let userMessage = try XCTUnwrap(try nodeStore.fetchMessages(nodeId: nodeId).first { $0.role == .user })
        XCTAssertTrue(try nodeStore.fetchMessageSourceMaterials(messageId: userMessage.id).isEmpty)
    }

    func testSourceMaterialsForUserMessageCachesEmptyLookupsUntilReload() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let conversation = NousNode(type: .conversation, title: "Plain chat")
        let userMessage = Message(nodeId: conversation.id, role: .user, content: "Plain message")
        try nodeStore.insertNode(conversation)
        try nodeStore.insertMessage(userMessage)
        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { SingleReplyLLMService(output: "answer") },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )
        vm.loadConversation(conversation)

        XCTAssertTrue(vm.sourceMaterials(for: userMessage).isEmpty)

        let sourceNode = NousNode(type: .source, title: "Late source", content: "Late source text")
        try nodeStore.insertSource(
            node: sourceNode,
            metadata: SourceMetadata(
                nodeId: sourceNode.id,
                kind: .youtube,
                originalURL: "https://www.youtube.com/watch?v=late",
                originalFilename: nil,
                contentHash: "late-source-material",
                ingestedAt: Date(timeIntervalSince1970: 1),
                extractionStatus: .ready,
                evidenceLevel: .summaryOnly
            ),
            chunks: [
                SourceChunk(
                    sourceNodeId: sourceNode.id,
                    ordinal: 0,
                    text: "Late source text",
                    createdAt: Date(timeIntervalSince1970: 1)
                )
            ]
        )
        try nodeStore.replaceMessageSourceMaterials([
            SourceMaterialContext(
                sourceNodeId: sourceNode.id,
                title: sourceNode.title,
                originalURL: "https://www.youtube.com/watch?v=late",
                originalFilename: nil,
                chunks: [
                    SourceChunkContext(
                        sourceNodeId: sourceNode.id,
                        ordinal: 0,
                        text: "Late source text",
                        similarity: nil
                    )
                ],
                evidenceLevel: .summaryOnly
            )
        ], for: userMessage.id)

        XCTAssertTrue(vm.sourceMaterials(for: userMessage).isEmpty)

        vm.loadConversation(conversation)
        XCTAssertEqual(vm.sourceMaterials(for: userMessage).count, 1)
    }

    func testSourceBriefingForUserMessageCachesEmptyLookupsUntilReload() throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let conversation = NousNode(type: .conversation, title: "Plain chat")
        let userMessage = Message(nodeId: conversation.id, role: .user, content: "Plain message")
        try nodeStore.insertNode(conversation)
        try nodeStore.insertMessage(userMessage)
        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { SingleReplyLLMService(output: "answer") },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )
        vm.loadConversation(conversation)

        XCTAssertNil(vm.sourceBriefing(for: userMessage))

        let sourceId = UUID()
        try nodeStore.replaceSourceBriefing(
            SourceBriefing(
                title: "Late brief",
                items: [
                    SourceBriefingItem(
                        sourceNodeId: sourceId,
                        headline: "Late source brief",
                        whatChanged: "The source now has a briefing.",
                        whyItMatters: "This proves empty cache behavior.",
                        alexRelevance: "It keeps render-time lookups quiet.",
                        tensionOrRisk: "None.",
                        suggestedNextAction: "Reload the conversation.",
                        evidence: "The source now has a briefing.",
                        confidence: 0.8
                    )
                ]
            ),
            for: userMessage.id
        )

        XCTAssertNil(vm.sourceBriefing(for: userMessage))

        vm.loadConversation(conversation)
        XCTAssertEqual(vm.sourceBriefing(for: userMessage)?.items.first?.headline, "Late source brief")
    }

    func testRegenerateLatestAssistantKeepsDocumentSourceMaterialAfterConversationReload() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let llm = RecordingReplyLLMService(output: "answer")

        let firstVM = ChatViewModel(
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

        firstVM.inputText = "Connect this report"
        await firstVM.send(attachments: [
            AttachedFileContext(
                name: "report.txt",
                extractedText: "Report preview",
                sourceText: "Full report says the source-only late section connects to runway decisions."
            )
        ])

        let nodeId = try XCTUnwrap(firstVM.currentNode?.id)
        let userMessage = try XCTUnwrap(try nodeStore.fetchMessages(nodeId: nodeId).first { $0.role == .user })
        XCTAssertEqual(try nodeStore.fetchMessageSourceMaterials(messageId: userMessage.id).count, 1)

        let reloadedVM = ChatViewModel(
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
        let reloadedNode = try XCTUnwrap(nodeStore.fetchNode(id: nodeId))
        reloadedVM.loadConversation(reloadedNode)

        await reloadedVM.regenerateLatestAssistant()

        let sourcePromptCount = llm.promptTexts.filter(Self.isDocumentSourcePrompt).count
        XCTAssertEqual(sourcePromptCount, 2)
    }

    func testSendRecoversRestoredConversationWhenCurrentNodeMissingFromStore() async throws {
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

        let missingNode = NousNode(type: .conversation, title: "Ghost Chat")
        vm.currentNode = missingNode
        vm.messages = [
            Message(nodeId: missingNode.id, role: .assistant, content: "Restored but not stored")
        ]
        scratchPadStore.activate(conversationId: missingNode.id)
        vm.inputText = "Why no reply?"

        await vm.send()

        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        let assistantMessage = try XCTUnwrap(vm.messages.last)
        let storedMessages = try nodeStore.fetchMessages(nodeId: nodeId)
        let storedNode = try XCTUnwrap(nodeStore.fetchNode(id: nodeId))

        XCTAssertNotEqual(nodeId, missingNode.id)
        XCTAssertEqual(vm.currentNode?.title, "Ghost Chat")
        XCTAssertEqual(assistantMessage.role, .assistant)
        XCTAssertEqual(assistantMessage.content, "unused")
        XCTAssertEqual(storedMessages.map(\.content), ["Restored but not stored", "Why no reply?", "unused"])
        XCTAssertTrue(storedMessages.allSatisfy { $0.nodeId == nodeId })
        XCTAssertTrue(storedNode.content.contains("Restored but not stored"))
        XCTAssertEqual(scratchPadStore.activeConversationId, nodeId)
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

    func testQuickActionOpeningUsesLocalModeMessageAndSkipsLLM() async throws {
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
        vm.lastPromptGovernanceTrace = PromptGovernanceTrace(
            promptLayers: ["previous_turn"],
            evidenceAttached: true,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false
        )

        await vm.beginQuickActionConversation(.direction)

        XCTAssertEqual(llm.generateCallCount, 0)
        XCTAssertEqual(vm.messages.map(\.content), [QuickActionMode.direction.openingMessage])
        XCTAssertEqual(vm.activeQuickActionMode, .direction)
        XCTAssertNil(vm.currentThinkingStartedAt)
        XCTAssertNil(vm.lastPromptGovernanceTrace)
    }

    func testQuickActionConversationUsesModeTitleForInstantOpening() async throws {
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

        XCTAssertEqual(vm.currentNode?.title, "Direction")
        XCTAssertEqual(storedNode.title, "Direction")
        XCTAssertEqual(assistant.content, QuickActionMode.direction.openingMessage)
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
        try await waitUntilOnMainActor {
            vm.currentNode != nil && vm.isGenerating && !vm.currentResponse.isEmpty
        }

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
        try await waitUntilOnMainActor {
            vm.currentNode != nil && vm.isGenerating && !vm.currentResponse.isEmpty
        }

        let originalNodeId = try XCTUnwrap(vm.currentNode?.id)
        let otherNode = NousNode(type: .conversation, title: "Other conversation")
        try nodeStore.insertNode(otherNode)

        vm.loadConversation(otherNode, cancelInFlightWork: true)
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

    func testGovernanceTelemetryAggregatesApiInferenceWithoutPromptText() throws {
        let suiteName = "ChatViewModelTests.api-inference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let telemetry = GovernanceTelemetryStore(defaults: defaults)

        telemetry.recordTurnInferenceTelemetry(
            TurnInferenceTelemetryRecord(
                provider: .gemini,
                modelName: "gemini-test",
                latencyTier: .fast,
                outcome: .completed,
                ttftSeconds: 1.0,
                streamDurationSeconds: 2.0,
                chunkCount: 2,
                averageChunkGapSeconds: 0.5,
                maxChunkGapSeconds: 0.5,
                outputCharacterCount: 12,
                stablePromptCharacterCount: 31,
                volatilePromptCharacterCount: 11,
                requestPromptCharacterCount: 42,
                usedCachedHistory: false,
                geminiUsage: nil
            ),
            at: Date(timeIntervalSince1970: 10)
        )
        telemetry.recordTurnInferenceTelemetry(
            TurnInferenceTelemetryRecord(
                provider: .openrouter,
                modelName: "anthropic/claude-sonnet-4.6",
                latencyTier: .normal,
                outcome: .completed,
                ttftSeconds: 3.0,
                streamDurationSeconds: 6.0,
                chunkCount: 3,
                averageChunkGapSeconds: 1.0,
                maxChunkGapSeconds: 1.5,
                outputCharacterCount: 24,
                stablePromptCharacterCount: 40,
                volatilePromptCharacterCount: 20,
                requestPromptCharacterCount: 60,
                usedCachedHistory: true,
                geminiUsage: GeminiUsageMetadata(
                    promptTokenCount: 100,
                    cachedContentTokenCount: 75,
                    candidatesTokenCount: 25,
                    thoughtsTokenCount: nil,
                    totalTokenCount: 125
                )
            ),
            at: Date(timeIntervalSince1970: 20)
        )
        telemetry.recordTurnInferenceTelemetry(
            TurnInferenceTelemetryRecord(
                provider: .claude,
                modelName: "claude-sonnet-4-6",
                latencyTier: .deep,
                outcome: .completed,
                ttftSeconds: 5.0,
                streamDurationSeconds: 10.0,
                chunkCount: 4,
                averageChunkGapSeconds: 2.0,
                maxChunkGapSeconds: 2.5,
                outputCharacterCount: 48,
                stablePromptCharacterCount: 80,
                volatilePromptCharacterCount: 30,
                requestPromptCharacterCount: 110,
                usedCachedHistory: false,
                geminiUsage: nil
            ),
            at: Date(timeIntervalSince1970: 30)
        )

        let summary = try XCTUnwrap(telemetry.turnInferenceTelemetrySummary)
        let last = try XCTUnwrap(summary.lastSnapshot)
        let encoded = String(data: try JSONEncoder().encode(last), encoding: .utf8) ?? ""

        XCTAssertEqual(summary.requestCount, 3)
        XCTAssertEqual(summary.averageTTFTSeconds ?? -1, 3.0, accuracy: 0.001)
        XCTAssertEqual(summary.fastRequestCount, 1)
        XCTAssertEqual(summary.normalRequestCount, 1)
        XCTAssertEqual(summary.deepRequestCount, 1)
        XCTAssertEqual(summary.averageFastTTFTSeconds ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(summary.averageNormalTTFTSeconds ?? -1, 3.0, accuracy: 0.001)
        XCTAssertEqual(summary.averageDeepTTFTSeconds ?? -1, 5.0, accuracy: 0.001)
        XCTAssertEqual(summary.averageStreamDurationSeconds, 6.0, accuracy: 0.001)
        XCTAssertEqual(summary.averageChunkGapSeconds ?? -1, 1.166, accuracy: 0.001)
        XCTAssertEqual(last.record.provider, .claude)
        XCTAssertEqual(last.record.modelName, "claude-sonnet-4-6")
        XCTAssertEqual(last.record.latencyTier, .deep)
        XCTAssertFalse(last.record.usedCachedHistory)
        XCTAssertNil(last.record.geminiUsage)
        XCTAssertFalse(encoded.contains("stable prompt text"))
        XCTAssertFalse(encoded.contains("volatile prompt text"))
    }

    func testTurnExecutorRecordsFastTierTimingAndPromptBudget() async throws {
        let clock = SequenceDateProvider([
            0.0,
            2.0,
            2.4,
            3.0
        ])
        let llm = TimedStreamingLLMService(chunks: ["Hel", "lo"])
        var records: [TurnInferenceTelemetryRecord] = []
        let executor = TurnExecutor(
            llmServiceProvider: { llm },
            shouldUseGeminiHistoryCache: { false },
            shouldPersistAssistantThinking: { true },
            recordTurnInferenceTelemetry: { records.append($0) },
            nowProvider: { clock.next() }
        )
        let plan = makeExecutorPlan(
            latencyTier: .fast,
            provider: .openrouter,
            stable: "stable prompt text",
            volatile: "volatile prompt text",
            transcriptContents: ["prior assistant context", "what does TTFT mean?"]
        )
        let sink = TurnSequencedEventSink(turnId: plan.turnId, sink: ChatViewModelNoOpTurnEventSink())

        let result = try await executor.execute(plan: plan, sink: sink, captureThinking: true)

        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(result?.assistantContent, "Hello")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.provider, .openrouter)
        XCTAssertEqual(record.modelName, "timed-test-model")
        XCTAssertEqual(record.latencyTier, .fast)
        XCTAssertEqual(record.outcome, .completed)
        XCTAssertEqual(record.ttftSeconds ?? -1, 2.0, accuracy: 0.001)
        XCTAssertEqual(record.streamDurationSeconds, 3.0, accuracy: 0.001)
        XCTAssertEqual(record.chunkCount, 2)
        XCTAssertEqual(record.averageChunkGapSeconds ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(record.maxChunkGapSeconds ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(record.outputCharacterCount, 5)
        XCTAssertEqual(record.stablePromptCharacterCount, "stable prompt text".count)
        XCTAssertEqual(record.volatilePromptCharacterCount, "volatile prompt text".count)
        XCTAssertFalse(record.usedCachedHistory)
        XCTAssertEqual(llm.thinkingHandlerInstallCount, 0)
    }

    func testTurnExecutorDoesNotRecordCompletedTelemetryForCancellation() async throws {
        var records: [TurnInferenceTelemetryRecord] = []
        let executor = TurnExecutor(
            llmServiceProvider: { CancellationFailingLLMService() },
            shouldUseGeminiHistoryCache: { false },
            recordTurnInferenceTelemetry: { records.append($0) },
            nowProvider: { Date(timeIntervalSince1970: 1) }
        )
        let plan = makeExecutorPlan(latencyTier: .normal)
        let sink = TurnSequencedEventSink(turnId: plan.turnId, sink: ChatViewModelNoOpTurnEventSink())

        let result = try await executor.execute(plan: plan, sink: sink)

        XCTAssertNil(result)
        XCTAssertTrue(records.isEmpty)
    }

    func testGovernanceTraceIncludesSummaryOutputPolicyLayer() {
        let trace = PromptContextAssembler.governanceTrace(
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

    private func makeExecutorPlan(
        latencyTier: TurnLatencyTier,
        provider: LLMProvider = .gemini,
        stable: String = "stable",
        volatile: String = "volatile",
        transcriptContents: [String] = ["hello"]
    ) -> TurnPlan {
        let node = NousNode(type: .conversation, title: "Executor test")
        let messages = transcriptContents.enumerated().map { offset, content in
            LLMMessage(role: offset == transcriptContents.count - 1 ? "user" : "assistant", content: content)
        }
        let userMessage = Message(nodeId: node.id, role: .user, content: transcriptContents.last ?? "hello")
        let prepared = PreparedConversationTurn(
            node: node,
            userMessage: userMessage,
            messagesAfterUserAppend: [userMessage]
        )
        return TurnPlan(
            turnId: UUID(),
            prepared: prepared,
            citations: [],
            promptTrace: PromptGovernanceTrace(
                promptLayers: [],
                evidenceAttached: false,
                safetyPolicyInvoked: false,
                highRiskQueryDetected: false
            ),
            effectiveMode: .companion,
            nextQuickActionModeIfCompleted: nil,
            judgeEventDraft: nil,
            turnSlice: TurnSystemSlice(stable: stable, volatile: volatile),
            transcriptMessages: messages,
            focusBlock: nil,
            provider: provider,
            latencyTier: latencyTier
        )
    }

    func testAssembleContextStableIncludesSummaryInstruction() {
        let slice = PromptContextAssembler.assembleContext(
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

    func testTextFileContextKeepsFullSourceTextBeyondChatPreview() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nous-source-text-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("long-report.txt")
        let fullText = String(repeating: "source body ", count: 420) + "late section survives for source ingestion"
        try Data(fullText.utf8).write(to: url)

        let context = try XCTUnwrap(AttachmentExtractor.fileContexts(from: [url]).first)

        XCTAssertEqual(context.extractedText?.count, 4_000)
        XCTAssertEqual(context.sourceText, fullText)
        XCTAssertFalse(context.extractedText?.contains("late section survives") ?? true)
    }

    func testDocumentAttachmentDuplicateCheckIncludesFullSourceText() {
        let sharedPreview = String(repeating: "same preview ", count: 334).prefix(4_000)
        let first = AttachedFileContext(
            name: "report.txt",
            extractedText: String(sharedPreview),
            sourceText: String(sharedPreview) + " first ending"
        )
        let second = AttachedFileContext(
            name: "report.txt",
            extractedText: String(sharedPreview),
            sourceText: String(sharedPreview) + " second ending"
        )
        let exactDuplicate = AttachedFileContext(
            name: "report.txt",
            extractedText: String(sharedPreview),
            sourceText: String(sharedPreview) + " first ending"
        )

        XCTAssertFalse(AttachmentLimitPolicy.isDuplicateNonImageAttachment(first, of: second))
        XCTAssertTrue(AttachmentLimitPolicy.isDuplicateNonImageAttachment(first, of: exactDuplicate))
    }

    @MainActor
    func testSourceIngestionKeepsFailedDuplicateFilenameAttachmentInTurn() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let llm = SingleReplyLLMService(output: "I connected the source.")
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

        vm.inputText = "Compare these"
        await vm.send(attachments: [
            AttachedFileContext(name: "report.pdf", extractedText: nil),
            AttachedFileContext(name: "report.pdf", extractedText: "Readable report text for source ingestion.")
        ])

        let nodeId = try XCTUnwrap(vm.currentNode?.id)
        let userMessage = try XCTUnwrap(try nodeStore.fetchMessages(nodeId: nodeId).first)
        XCTAssertTrue(userMessage.content.contains("Files: report.pdf"))
    }

    @MainActor
    func testSlowSourceIngestionMarksTurnGeneratingBeforeFetchCompletes() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let blockingFetcher = BlockingSourceFetcher()
        let sourceIngestion = SourceIngestionService(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingProvider: embeddingService,
            fetcher: blockingFetcher
        )
        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            sourceIngestionService: sourceIngestion,
            llmServiceProvider: { SingleReplyLLMService(output: "I connected the source.") },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: makeScratchPadStore(nodeStore: nodeStore)
        )

        vm.inputText = "Read https://example.com/slow"
        let sendTask = Task { @MainActor in
            await vm.send()
        }
        await blockingFetcher.waitUntilStarted()

        XCTAssertTrue(vm.isGenerating)

        await blockingFetcher.finish()
        await sendTask.value
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

    @MainActor
    func test_backgroundTurnCompletion_setsHasUnseenCompletion() async throws {
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

        let nodeA = NousNode(type: .conversation, title: "A")
        try nodeStore.insertNode(nodeA)
        let nodeB = NousNode(type: .conversation, title: "B")
        try nodeStore.insertNode(nodeB)

        vm.loadConversation(nodeA)
        let sessionA = try XCTUnwrap(vm.currentStreamingSession)

        let turnId = UUID()
        let task = Task<Void, Never> { }
        sessionA.beginTurn(turnId: turnId, task: task)

        // Switch to B BEFORE the simulated finish.
        vm.loadConversation(nodeB)

        // Simulate the originating turn finishing in the background.
        _ = sessionA.captureFinish(turnId: turnId, viewingNow: false, error: nil)

        XCTAssertTrue(sessionA.hasUnseenCompletion)
    }

    @MainActor
    func test_loadConversation_doesNotCancelInFlightTaskOnOtherConversation() async throws {
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

        let nodeA = NousNode(type: .conversation, title: "A")
        try nodeStore.insertNode(nodeA)
        let nodeB = NousNode(type: .conversation, title: "B")
        try nodeStore.insertNode(nodeB)

        vm.loadConversation(nodeA)
        let sessionA = try XCTUnwrap(vm.currentStreamingSession)
        let started = expectation(description: "A task started")
        let task = Task<Void, Never> {
            started.fulfill()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        sessionA.beginTurn(turnId: UUID(), task: task)
        await fulfillment(of: [started], timeout: 1.0)

        vm.loadConversation(nodeB)

        XCTAssertFalse(task.isCancelled)
        // Task 5 migrates the in-flight slots to the newly-bound session so
        // `isActiveResponseTask` keeps recognizing the running turn. After
        // the switch, the live task lives on the current streaming session
        // (sessionB) rather than the stale sessionA reference.
        XCTAssertNotNil(vm.currentStreamingSession?.inFlightTask)

        task.cancel()
    }
}

private actor BlockingSourceFetcher: SourceFetching {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func fetch(url: URL) async throws -> SourceFetchedDocument {
        didStart = true
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters {
            waiter.resume()
        }

        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }

        return SourceFetchedDocument(
            url: url,
            title: "Slow source",
            text: "Slow source body about connecting external material."
        )
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}
