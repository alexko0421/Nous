import XCTest
@testable import Nous

final class RAGPipelineTests: XCTestCase {
    var nodeStore: NodeStore!
    var vectorStore: VectorStore!

    override func setUp() {
        super.setUp()
        nodeStore = try! NodeStore(path: ":memory:")
        vectorStore = VectorStore(nodeStore: nodeStore)
    }

    // MARK: - Test 1: RAG search returns the most relevant node

    func testBuildContextIncludesRelevantNodes() throws {
        // Insert a node with embedding close to query
        var matchNode = NousNode(type: .note, title: "Swift concurrency guide")
        matchNode.embedding = [1.0, 0.0, 0.0]
        try nodeStore.insertNode(matchNode)

        // Insert a node with embedding far from query
        var otherNode = NousNode(type: .note, title: "Recipe for banana bread")
        otherNode.embedding = [0.0, 0.0, 1.0]
        try nodeStore.insertNode(otherNode)

        // Query embedding similar to matchNode
        let queryEmbedding: [Float] = [0.99, 0.01, 0.0]
        let results = try vectorStore.search(query: queryEmbedding, topK: 5)

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results[0].node.title, "Swift concurrency guide")
    }

    // MARK: - Test 2: assembleContext includes expected content

    func testContextAssembly() {
        let node1 = NousNode(
            type: .note,
            title: "Actor isolation notes",
            content: "Actors protect mutable state by serializing access."
        )
        let node2 = NousNode(
            type: .note,
            title: "Async/Await overview",
            content: "Async/await simplifies asynchronous code in Swift."
        )

        let citations = [
            SearchResult(node: node1, similarity: 0.92),
            SearchResult(node: node2, similarity: 0.78)
        ]
        let recentConversation = NousNode(
            type: .conversation,
            title: "Funding worries",
            content: "Alex said cash runway is tight and school is only for visa status."
        )

        let projectGoal = "Build a Swift concurrency learning app"
        let userMemory = """
        ## Identity
        - Alex is a solo founder.
        """

        let context = ChatViewModel.assembleContext(
            globalMemory: userMemory,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [recentConversation],
            citations: citations,
            projectGoal: projectGoal
        )

        // Verify anchor prompt is present without depending on one exact language variant
        XCTAssertTrue(context.contains("Nous"))

        // Verify long-term user memory is included
        XCTAssertTrue(context.contains("Alex is a solo founder"))

        // Verify project goal is included
        XCTAssertTrue(context.contains(projectGoal))

        // Verify recent conversation is included
        XCTAssertTrue(context.contains("Funding worries"))
        XCTAssertTrue(context.contains("cash runway is tight"))

        // Verify citation titles are present
        XCTAssertTrue(context.contains("Actor isolation notes"))
        XCTAssertTrue(context.contains("Async/Await overview"))

        // Verify content snippets are present
        XCTAssertTrue(context.contains("Actors protect mutable state"))
        XCTAssertTrue(context.contains("Async/await simplifies"))

        // Verify relevance percentages
        XCTAssertTrue(context.contains("92%"))
        XCTAssertTrue(context.contains("78%"))
    }

    func testInteractiveClarificationInstructionsAppearOnlyWhenEnabled() {
        let enabled = ChatViewModel.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            activeQuickActionMode: .direction,
            allowInteractiveClarification: true
        )
        let disabled = ChatViewModel.assembleContext(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            activeQuickActionMode: .direction,
            allowInteractiveClarification: false
        )

        XCTAssertTrue(enabled.contains("INTERACTIVE CLARIFICATION UI"))
        XCTAssertTrue(enabled.contains("understanding phase"))
        XCTAssertTrue(enabled.contains("more than one clarification turn"))
        XCTAssertFalse(disabled.contains("INTERACTIVE CLARIFICATION UI"))
        XCTAssertTrue(disabled.contains("ACTIVE QUICK MODE: Direction"))
    }

    func testQuickActionModeStaysActiveOnlyWhenAssistantStillClarifies() {
        let clarificationReply = """
        I need one more distinction before I answer.
        <clarify>
        <question>What kind of situation is this?</question>
        <option>Work</option>
        <option>School</option>
        <option>Relationship</option>
        </clarify>
        """
        let normalReply = "Based on what you've shared, the clearest next step is to talk to him directly."
        let understandingQuestion = """
        <phase>understanding</phase>
        Before I jump in, what feels most stuck right now?
        """

        XCTAssertEqual(
            ChatViewModel.updatedQuickActionMode(
                currentMode: .direction,
                assistantContent: clarificationReply
            ),
            .direction
        )
        XCTAssertEqual(
            ChatViewModel.updatedQuickActionMode(
                currentMode: .direction,
                assistantContent: understandingQuestion
            ),
            .direction
        )
        XCTAssertNil(
            ChatViewModel.updatedQuickActionMode(
                currentMode: .direction,
                assistantContent: normalReply
            )
        )
    }

    func testQuickActionOpeningPromptStartsWithAssistantQuestioning() {
        let prompt = ChatViewModel.quickActionOpeningPrompt(for: .mentalHealth)

        XCTAssertTrue(prompt.contains("Start the conversation yourself"))
        XCTAssertTrue(prompt.contains("Ask one short, warm opening question"))
        XCTAssertTrue(prompt.contains("Mental Health"))
        XCTAssertTrue(prompt.contains("do not use the clarification card yet"))
        XCTAssertTrue(prompt.contains("<phase>understanding</phase>"))
    }
}
