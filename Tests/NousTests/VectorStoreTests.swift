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
}
