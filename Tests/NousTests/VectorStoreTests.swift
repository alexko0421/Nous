import XCTest
@testable import Nous

final class VectorStoreTests: XCTestCase {
    var nodeStore: NodeStore!
    var vectorStore: VectorStore!

    override func setUp() {
        super.setUp()
        nodeStore = try! NodeStore(path: ":memory:")
        vectorStore = VectorStore(nodeStore: nodeStore)
    }

    func testCosineSimilarityIdentical() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [1, 0, 0]
        let sim = vectorStore.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 1.0, accuracy: 0.001)
    }

    func testCosineSimilarityOrthogonal() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        let sim = vectorStore.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0.0, accuracy: 0.001)
    }

    func testCosineSimilarityOpposite() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [-1, 0, 0]
        let sim = vectorStore.cosineSimilarity(a, b)
        XCTAssertEqual(sim, -1.0, accuracy: 0.001)
    }

    func testSearchReturnsTopKByCosineSimilarity() throws {
        var n1 = NousNode(type: .note, title: "Close match")
        n1.embedding = [0.9, 0.1, 0.0]
        try nodeStore.insertNode(n1)

        var n2 = NousNode(type: .note, title: "Far match")
        n2.embedding = [0.0, 0.0, 1.0]
        try nodeStore.insertNode(n2)

        var n3 = NousNode(type: .note, title: "Medium match")
        n3.embedding = [0.5, 0.5, 0.0]
        try nodeStore.insertNode(n3)

        let query: [Float] = [1.0, 0.0, 0.0]
        let results = try vectorStore.search(query: query, topK: 2)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].node.title, "Close match")
        XCTAssertEqual(results[1].node.title, "Medium match")
    }

    func testSearchExcludesNodeById() throws {
        var n1 = NousNode(type: .note, title: "Self")
        n1.embedding = [1.0, 0.0, 0.0]
        try nodeStore.insertNode(n1)

        var n2 = NousNode(type: .note, title: "Other")
        n2.embedding = [0.9, 0.1, 0.0]
        try nodeStore.insertNode(n2)

        let query: [Float] = [1.0, 0.0, 0.0]
        let results = try vectorStore.search(query: query, topK: 5, excludeIds: [n1.id])

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].node.title, "Other")
    }

    func testFindSemanticNeighborsAboveThreshold() throws {
        var n1 = NousNode(type: .note, title: "A")
        n1.embedding = [1.0, 0.0, 0.0]
        try nodeStore.insertNode(n1)

        var n2 = NousNode(type: .note, title: "B similar")
        n2.embedding = [0.95, 0.05, 0.0]
        try nodeStore.insertNode(n2)

        var n3 = NousNode(type: .note, title: "C different")
        n3.embedding = [0.0, 1.0, 0.0]
        try nodeStore.insertNode(n3)

        let neighbors = try vectorStore.findSemanticNeighbors(for: n1, threshold: 0.75)
        XCTAssertEqual(neighbors.count, 1)
        XCTAssertEqual(neighbors[0].node.title, "B similar")
    }

    func testSearchForChatCitationsPreservesTopSemanticHits() throws {
        let now = Date()
        try insertNode(
            title: "Recent strongest",
            embedding: [0.99, 0.01, 0.0],
            createdAt: now.addingTimeInterval(-86_400)
        )
        try insertNode(
            title: "Recent second",
            embedding: [0.9, 0.1, 0.0],
            createdAt: now.addingTimeInterval(-2 * 86_400)
        )
        try insertNode(
            title: "Recent third",
            embedding: [0.82, 0.18, 0.0],
            createdAt: now.addingTimeInterval(-3 * 86_400)
        )
        try insertNode(
            title: "Old spark",
            embedding: [0.6, 0.4, 0.0],
            createdAt: now.addingTimeInterval(-120 * 86_400)
        )

        let results = try vectorStore.searchForChatCitations(
            query: [1.0, 0.0, 0.0],
            topK: 4,
            now: now
        )

        XCTAssertEqual(results.map(\.node.title).prefix(3), [
            "Recent strongest",
            "Recent second",
            "Recent third"
        ])
        XCTAssertTrue(results.prefix(3).allSatisfy { $0.lane == .semantic })
    }

    func testSearchForChatCitationsIncludesOneOldRelevantSpark() throws {
        let now = Date()
        try insertNode(
            title: "Recent strongest",
            embedding: [0.99, 0.01, 0.0],
            createdAt: now.addingTimeInterval(-86_400)
        )
        try insertNode(
            title: "Recent second",
            embedding: [0.93, 0.07, 0.0],
            createdAt: now.addingTimeInterval(-2 * 86_400)
        )
        try insertNode(
            title: "Recent third",
            embedding: [0.86, 0.14, 0.0],
            createdAt: now.addingTimeInterval(-3 * 86_400)
        )
        try insertNode(
            title: "Recent filler",
            embedding: [0.8, 0.2, 0.0],
            createdAt: now.addingTimeInterval(-4 * 86_400)
        )
        try insertNode(
            title: "Old spark",
            embedding: [0.6, 0.4, 0.0],
            createdAt: now.addingTimeInterval(-120 * 86_400)
        )

        let results = try vectorStore.searchForChatCitations(
            query: [1.0, 0.0, 0.0],
            topK: 4,
            now: now
        )

        XCTAssertTrue(results.map(\.node.title).contains("Old spark"))
        XCTAssertFalse(results.map(\.node.title).contains("Recent filler"))
        XCTAssertEqual(results.first(where: { $0.node.title == "Old spark" })?.lane, .longGap)
    }

    func testSearchForChatCitationsRejectsOldButLowSimilarityNoise() throws {
        let now = Date()
        try insertNode(
            title: "Recent strongest",
            embedding: [0.99, 0.01, 0.0],
            createdAt: now.addingTimeInterval(-86_400)
        )
        try insertNode(
            title: "Recent second",
            embedding: [0.92, 0.08, 0.0],
            createdAt: now.addingTimeInterval(-2 * 86_400)
        )
        try insertNode(
            title: "Recent third",
            embedding: [0.84, 0.16, 0.0],
            createdAt: now.addingTimeInterval(-3 * 86_400)
        )
        try insertNode(
            title: "Recent filler",
            embedding: [0.78, 0.22, 0.0],
            createdAt: now.addingTimeInterval(-4 * 86_400)
        )
        try insertNode(
            title: "Old noise",
            embedding: [0.2, 0.0, 0.98],
            createdAt: now.addingTimeInterval(-240 * 86_400)
        )

        let results = try vectorStore.searchForChatCitations(
            query: [1.0, 0.0, 0.0],
            topK: 4,
            now: now
        )

        XCTAssertTrue(results.map(\.node.title).contains("Recent filler"))
        XCTAssertFalse(results.map(\.node.title).contains("Old noise"))
    }

    func testSearchForChatCitationsFallsBackToPureSimilarityWhenNoEligibleLongGapHit() throws {
        let now = Date()
        try insertNode(
            title: "Recent strongest",
            embedding: [0.99, 0.01, 0.0],
            createdAt: now.addingTimeInterval(-86_400)
        )
        try insertNode(
            title: "Recent second",
            embedding: [0.93, 0.07, 0.0],
            createdAt: now.addingTimeInterval(-2 * 86_400)
        )
        try insertNode(
            title: "Recent third",
            embedding: [0.86, 0.14, 0.0],
            createdAt: now.addingTimeInterval(-3 * 86_400)
        )
        try insertNode(
            title: "Too weak old",
            embedding: [0.3, 0.95, 0.0],
            createdAt: now.addingTimeInterval(-120 * 86_400)
        )
        try insertNode(
            title: "Recent filler",
            embedding: [0.8, 0.2, 0.0],
            createdAt: now.addingTimeInterval(-4 * 86_400)
        )

        let semanticOnly = try vectorStore.search(query: [1.0, 0.0, 0.0], topK: 4)
        let chatResults = try vectorStore.searchForChatCitations(
            query: [1.0, 0.0, 0.0],
            topK: 4,
            now: now
        )

        XCTAssertEqual(chatResults.map(\.node.title), semanticOnly.map(\.node.title))
    }

    func testSearchForChatCitationsReturnsEmptyWhenMatchesAreTooWeakToSurface() throws {
        let now = Date()
        try insertNode(
            title: "Weak one",
            embedding: [0.44, 0.90, 0.0],
            createdAt: now.addingTimeInterval(-86_400)
        )
        try insertNode(
            title: "Weak two",
            embedding: [0.43, 0.91, 0.0],
            createdAt: now.addingTimeInterval(-2 * 86_400)
        )
        try insertNode(
            title: "Weak three",
            embedding: [0.41, 0.92, 0.0],
            createdAt: now.addingTimeInterval(-3 * 86_400)
        )

        let results = try vectorStore.searchForChatCitations(
            query: [1.0, 0.0, 0.0],
            queryText: "Should this even find anything?",
            topK: 4,
            now: now
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testSearchForChatCitationsBuildsQueryAnchoredConversationPreview() throws {
        let now = Date()
        let transcript = """
        Alex: We were talking about coffee beans and morning routines.

        Nous: That was mostly about daily habits.

        Alex: I am scared of failing if I apply to YC this year.

        Nous: The fear of failure is still sitting under the YC decision.
        """

        var node = NousNode(
            type: .conversation,
            title: "YC fear thread",
            content: transcript,
            createdAt: now.addingTimeInterval(-90 * 86_400),
            updatedAt: now.addingTimeInterval(-90 * 86_400)
        )
        node.embedding = [1.0, 0.0, 0.0]
        try nodeStore.insertNode(node)

        let results = try vectorStore.searchForChatCitations(
            query: [1.0, 0.0, 0.0],
            queryText: "failure yc",
            topK: 3,
            now: now
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].surfacedSnippet.contains("fear of failure"))
        XCTAssertFalse(results[0].surfacedSnippet.contains("coffee beans"))
    }

    func testSearchForChatCitationsUsesSourceChunksForExistingSourceNodes() throws {
        let now = Date()
        var source = NousNode(
            type: .source,
            title: "Long external source",
            content: "Intro section that does not mention the later visa runway material.",
            createdAt: now,
            updatedAt: now
        )
        source.embedding = [0.0, 1.0, 0.0]
        try nodeStore.insertNode(source)
        try nodeStore.replaceSourceChunks([
            SourceChunk(
                sourceNodeId: source.id,
                ordinal: 0,
                text: "Intro section that does not mention the later material.",
                embedding: [0.0, 1.0, 0.0],
                createdAt: now
            ),
            SourceChunk(
                sourceNodeId: source.id,
                ordinal: 1,
                text: "Deep section about F-1 visa runway and source connection work.",
                embedding: [1.0, 0.0, 0.0],
                createdAt: now
            )
        ], for: source.id)

        let results = try vectorStore.searchForChatCitations(
            query: [1.0, 0.0, 0.0],
            queryText: "F-1 visa runway source connection",
            topK: 3,
            now: now
        )

        XCTAssertEqual(results.first?.node.id, source.id)
        XCTAssertEqual(results.first?.surfacedSnippet.contains("F-1 visa runway"), true)
    }

    private func insertNode(title: String, embedding: [Float], createdAt: Date) throws {
        let node = NousNode(
            type: .note,
            title: title,
            embedding: embedding,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try nodeStore.insertNode(node)
    }
}
