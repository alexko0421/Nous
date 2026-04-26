import XCTest
@testable import Nous

final class GraphEngineTests: XCTestCase {
    var nodeStore: NodeStore!
    var vectorStore: VectorStore!
    var engine: GraphEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        nodeStore = try NodeStore(path: ":memory:")
        vectorStore = VectorStore(nodeStore: nodeStore)
        engine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
    }

    func testForceLayoutProducesPositions() throws {
        var n1 = NousNode(type: .note, title: "A")
        n1.embedding = [1.0, 0.0]
        var n2 = NousNode(type: .note, title: "B")
        n2.embedding = [0.0, 1.0]
        try nodeStore.insertNode(n1)
        try nodeStore.insertNode(n2)

        let positions = try engine.computeLayout()
        XCTAssertEqual(positions.count, 2)
        let p1 = positions[n1.id]!
        let p2 = positions[n2.id]!
        let distance = sqrt(pow(p1.x - p2.x, 2) + pow(p1.y - p2.y, 2))
        XCTAssertGreaterThan(distance, 10)
    }

    func testGenerateSemanticEdges() throws {
        var n1 = NousNode(type: .note, title: "A")
        n1.embedding = [1.0, 0.0, 0.0]
        var n2 = NousNode(type: .note, title: "B similar")
        n2.embedding = [0.95, 0.05, 0.0]
        var n3 = NousNode(type: .note, title: "C different")
        n3.embedding = [0.0, 0.0, 1.0]
        try nodeStore.insertNode(n1)
        try nodeStore.insertNode(n2)
        try nodeStore.insertNode(n3)

        try engine.generateSemanticEdges(for: n1)
        let edges = try nodeStore.fetchEdges(nodeId: n1.id)
        XCTAssertEqual(edges.count, 1)
        XCTAssertTrue(edges[0].sourceId == n1.id || edges[0].targetId == n1.id)
        XCTAssertGreaterThan(edges[0].strength, 0.75)
    }

}
