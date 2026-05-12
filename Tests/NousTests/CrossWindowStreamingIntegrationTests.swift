import XCTest
@testable import Nous

/// Integration coverage for the cross-window streaming survival feature
/// (Tasks 1-8 of cross-window-streaming).
///
/// These tests exercise the full ChatViewModel + ConversationStreamingSession
/// path the user actually traverses:
///   - Send a turn in conversation A
///   - Switch to B mid-stream
///   - Either continue streaming (background append) or finish the turn
///   - Switch back to A and assert the right state
///
/// We drive the streaming session directly (no real LLM) — the integration
/// surface under test is the ChatViewModel <-> ConversationSessionStore
/// <-> ConversationStreamingSession wiring, not the LLM transport.
@MainActor
final class CrossWindowStreamingIntegrationTests: XCTestCase {

    private func makeScratchPadStore(nodeStore: NodeStore) -> ScratchPadStore {
        let suiteName = "CrossWindowStreamingIntegrationTests.scratchpad.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ScratchPadStore(nodeStore: nodeStore, defaults: defaults)
    }

    private func makeChatViewModel() throws -> (ChatViewModel, NodeStore) {
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
        return (vm, nodeStore)
    }

    /// Scenario: send in A → switch to B mid-stream → keep accumulating →
    /// switch back to A → the accumulated buffer is visible and isGenerating
    /// is still true.
    func test_sendInA_switchToB_andBack_preservesAccumulatedStream() async throws {
        let (vm, nodeStore) = try makeChatViewModel()

        let nodeA = NousNode(type: .conversation, title: "A")
        try nodeStore.insertNode(nodeA)
        let nodeB = NousNode(type: .conversation, title: "B")
        try nodeStore.insertNode(nodeB)

        vm.loadConversation(nodeA)
        let sessionA = try XCTUnwrap(vm.currentStreamingSession)

        // Begin a fake turn that idles until cancelled, simulating an in-flight
        // LLM stream we can poke buffers on.
        let started = expectation(description: "A task started")
        let task = Task<Void, Never> {
            started.fulfill()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        sessionA.beginTurn(turnId: UUID(), task: task)
        await fulfillment(of: [started], timeout: 1.0)

        // Partial stream produced before the user navigates away.
        sessionA.currentResponse = "hello, w"

        // Switch away to B mid-stream.
        vm.loadConversation(nodeB)
        XCTAssertEqual(vm.currentResponse, "")
        XCTAssertFalse(vm.isGenerating)

        // A is still streaming in the background — more deltas arrive while
        // the user is looking at B.
        sessionA.currentResponse = "hello, world. and more."

        // Return to A — the rebound view-model should expose the accumulated
        // buffer and the still-running generation state.
        vm.loadConversation(nodeA)
        XCTAssertEqual(vm.currentResponse, "hello, world. and more.")
        XCTAssertTrue(vm.isGenerating)
        XCTAssertNotNil(vm.currentStreamingSession?.inFlightTask)

        task.cancel()
    }

    /// Scenario: send in A → switch to B → turn finishes in the background →
    /// A's session reports `hasUnseenCompletion = true` → re-enter A → the
    /// flag clears (because `loadConversation` calls `markViewed()`).
    func test_backgroundCompletion_setsUnseenAndClearsOnReentry() async throws {
        let (vm, nodeStore) = try makeChatViewModel()

        let nodeA = NousNode(type: .conversation, title: "A")
        try nodeStore.insertNode(nodeA)
        let nodeB = NousNode(type: .conversation, title: "B")
        try nodeStore.insertNode(nodeB)

        vm.loadConversation(nodeA)
        let sessionA = try XCTUnwrap(vm.currentStreamingSession)

        let turnId = UUID()
        sessionA.beginTurn(turnId: turnId, task: Task<Void, Never> { })

        // User navigates to B before the turn finishes.
        vm.loadConversation(nodeB)

        // The originating turn completes in the background.
        _ = sessionA.captureFinish(turnId: turnId, viewingNow: false, error: nil)
        XCTAssertTrue(sessionA.hasUnseenCompletion)

        // User re-enters A — the dot clears.
        vm.loadConversation(nodeA)
        XCTAssertFalse(sessionA.hasUnseenCompletion)
    }
}
