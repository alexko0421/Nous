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

        let projectGoal = "Build a Swift concurrency learning app"

        let context = ChatViewModel.assembleContext(citations: citations, projectGoal: projectGoal)

        // Verify system prompt is present
        XCTAssertTrue(context.contains("You are Nous"))

        // Verify project goal is included
        XCTAssertTrue(context.contains(projectGoal))

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
}
