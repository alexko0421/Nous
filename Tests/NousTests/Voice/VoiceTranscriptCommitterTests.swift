import XCTest
@testable import Nous

@MainActor
final class VoiceTranscriptCommitterTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var sessionStore: ConversationSessionStore!
    private var tempDBPath: String!
    private var scratchPadDefaultsSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDBPath = NSTemporaryDirectory() + "voice-committer-test-\(UUID().uuidString).db"
        nodeStore = try NodeStore(path: tempDBPath)
        sessionStore = ConversationSessionStore(nodeStore: nodeStore)
        scratchPadDefaultsSuiteName = "VoiceTranscriptCommitterTests.scratchpad.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        if let suite = scratchPadDefaultsSuiteName {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        sessionStore = nil
        nodeStore = nil
        try? FileManager.default.removeItem(atPath: tempDBPath)
        try await super.tearDown()
    }

    // MARK: - Tests

    func testCommitsFinalizedUserLineToBoundConversation() throws {
        let conversation = try sessionStore.startConversation(title: "Test")
        let viewModel = makeChatViewModel(currentNode: conversation)
        let controller = VoiceCommandController()
        let committer = VoiceTranscriptCommitter(
            voiceController: controller,
            chatViewModel: viewModel
        )

        controller.boundConversationId = conversation.id
        let line = VoiceTranscriptLine(
            id: UUID(),
            role: .user,
            text: "voice content",
            isFinal: true,
            createdAt: Date()
        )

        controller.onUserUtteranceFinalized?(line)

        let messages = try nodeStore.fetchMessages(nodeId: conversation.id)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.source, .voice)
        XCTAssertEqual(messages.first?.content, "voice content")
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertTrue(committer.committedLineIds.contains(line.id))
    }

    func testIgnoresAssistantLines() throws {
        let conversation = try sessionStore.startConversation(title: "Test")
        let viewModel = makeChatViewModel(currentNode: conversation)
        let controller = VoiceCommandController()
        let committer = VoiceTranscriptCommitter(
            voiceController: controller,
            chatViewModel: viewModel
        )
        // Retain the committer for the duration of the test (closures are
        // weakly captured, so without a strong reference they no-op).
        _ = committer

        controller.boundConversationId = conversation.id
        let assistantLine = VoiceTranscriptLine(
            id: UUID(),
            role: .assistant,
            text: "should be ignored",
            isFinal: true,
            createdAt: Date()
        )

        controller.onUserUtteranceFinalized?(assistantLine)

        let messages = try nodeStore.fetchMessages(nodeId: conversation.id)
        XCTAssertEqual(messages.count, 0)
    }

    func testDeduplicatesSameLineId() throws {
        let conversation = try sessionStore.startConversation(title: "Test")
        let viewModel = makeChatViewModel(currentNode: conversation)
        let controller = VoiceCommandController()
        let committer = VoiceTranscriptCommitter(
            voiceController: controller,
            chatViewModel: viewModel
        )
        _ = committer

        controller.boundConversationId = conversation.id
        let line = VoiceTranscriptLine(
            id: UUID(),
            role: .user,
            text: "duplicate",
            isFinal: true,
            createdAt: Date()
        )
        controller.onUserUtteranceFinalized?(line)
        controller.onUserUtteranceFinalized?(line)

        let messages = try nodeStore.fetchMessages(nodeId: conversation.id)
        XCTAssertEqual(messages.count, 1, "second commit with same id should no-op")
    }

    func testTerminationResetsDedupSet() throws {
        let conversation = try sessionStore.startConversation(title: "Test")
        let viewModel = makeChatViewModel(currentNode: conversation)
        let controller = VoiceCommandController()
        let committer = VoiceTranscriptCommitter(
            voiceController: controller,
            chatViewModel: viewModel
        )

        controller.boundConversationId = conversation.id
        let line = VoiceTranscriptLine(
            id: UUID(),
            role: .user,
            text: "before",
            isFinal: true,
            createdAt: Date()
        )
        controller.onUserUtteranceFinalized?(line)
        XCTAssertEqual(committer.committedLineIds.count, 1)

        controller.onVoiceSessionTerminated?()
        XCTAssertEqual(committer.committedLineIds.count, 0)
    }

    // MARK: - Helpers

    private func makeChatViewModel(currentNode: NousNode?) -> ChatViewModel {
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)

        let defaults = UserDefaults(suiteName: scratchPadDefaultsSuiteName)!
        defaults.removePersistentDomain(forName: scratchPadDefaultsSuiteName)
        let scratchPadStore = ScratchPadStore(nodeStore: nodeStore, defaults: defaults)

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            conversationSessionStore: sessionStore,
            llmServiceProvider: { nil },
            currentProviderProvider: { .local },
            judgeLLMServiceFactory: { nil },
            scratchPadStore: scratchPadStore
        )
        vm.currentNode = currentNode
        return vm
    }
}
