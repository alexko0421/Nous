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
        XCTAssertEqual(edges[0].relationKind, .topicSimilarity)
        XCTAssertFalse(edges[0].explanation?.isEmpty ?? true)
    }

    func testGenerateSemanticEdgesUsesAtomRelationships() throws {
        var n1 = NousNode(type: .note, title: "School pressure")
        n1.embedding = [1.0, 0.0, 0.0]
        var n2 = NousNode(type: .conversation, title: "Shipping pressure")
        n2.embedding = [0.98, 0.02, 0.0]
        try nodeStore.insertNode(n1)
        try nodeStore.insertNode(n2)

        let sourceAtom = MemoryAtom(
            type: .pattern,
            statement: "Alex turns uncertainty into speed when there is no safety net.",
            scope: .conversation,
            scopeRefId: n1.id,
            sourceNodeId: n1.id
        )
        let targetAtom = MemoryAtom(
            type: .insight,
            statement: "Shipping faster is being used to manage uncertainty.",
            scope: .conversation,
            scopeRefId: n2.id,
            sourceNodeId: n2.id
        )
        try nodeStore.insertMemoryAtom(sourceAtom)
        try nodeStore.insertMemoryAtom(targetAtom)

        try engine.generateSemanticEdges(for: n1)

        let edge = try XCTUnwrap(nodeStore.fetchEdges(nodeId: n1.id).first)
        XCTAssertEqual(edge.relationKind, .samePattern)
        XCTAssertGreaterThan(edge.confidence, 0.75)
        XCTAssertEqual(edge.sourceEvidence, "Alex turns uncertainty into speed when there is no safety net.")
        XCTAssertEqual(edge.targetEvidence, "Shipping faster is being used to manage uncertainty.")
        XCTAssertEqual(edge.sourceAtomId, sourceAtom.id)
        XCTAssertEqual(edge.targetAtomId, targetAtom.id)
    }

    func testRelationTelemetryTracksSemanticCandidatesAndWrites() throws {
        let telemetry = GalaxyRelationTelemetry()
        engine = GraphEngine(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            relationJudge: GalaxyRelationJudge(telemetry: telemetry),
            telemetry: telemetry
        )
        var n1 = NousNode(type: .note, title: "A")
        n1.embedding = [1.0, 0.0, 0.0]
        var n2 = NousNode(type: .note, title: "B similar")
        n2.embedding = [0.95, 0.05, 0.0]
        try nodeStore.insertNode(n1)
        try nodeStore.insertNode(n2)

        try engine.generateSemanticEdges(for: n1)

        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.relationCandidateCount, 1)
        XCTAssertEqual(snapshot.localVerdictCount, 1)
        XCTAssertEqual(snapshot.semanticEdgeWriteCount, 1)
    }

    func testLLMNoneKeepsLocalSimilarityEdgeVisible() async throws {
        engine = GraphEngine(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            relationJudge: GalaxyRelationJudge(
                llmServiceProvider: {
                    StaticGraphRelationLLMService(output: """
                    {
                      "relation": "none",
                      "confidence": 0.95,
                      "explanation": "not useful",
                      "source_evidence": "source",
                      "target_evidence": "target",
                      "source_atom_id": null,
                      "target_atom_id": null
                    }
                    """)
                }
            )
        )
        var n1 = NousNode(type: .note, title: "A")
        n1.embedding = [1.0, 0.0, 0.0]
        var n2 = NousNode(type: .note, title: "B similar")
        n2.embedding = [0.95, 0.05, 0.0]
        try nodeStore.insertNode(n1)
        try nodeStore.insertNode(n2)

        try await engine.generateSemanticEdgesWithRefinement(for: n1, maxCandidates: 1)

        let edge = try XCTUnwrap(nodeStore.fetchEdges(nodeId: n1.id).first)
        XCTAssertEqual(edge.relationKind, .topicSimilarity)
        XCTAssertGreaterThan(edge.strength, 0.75)
    }

    func testGenerateSharedEdges() throws {
        let project = Project(title: "P1")
        try nodeStore.insertProject(project)
        let n1 = NousNode(type: .note, title: "A", projectId: project.id)
        let n2 = NousNode(type: .note, title: "B", projectId: project.id)
        let n3 = NousNode(type: .note, title: "C")
        try nodeStore.insertNode(n1)
        try nodeStore.insertNode(n2)
        try nodeStore.insertNode(n3)

        try engine.generateSharedEdges(for: n1)
        let edges = try nodeStore.fetchEdges(nodeId: n1.id)
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].type, .shared)
        XCTAssertEqual(edges[0].relationKind, .topicSimilarity)
        XCTAssertEqual(edges[0].explanation, "These nodes belong to the same project.")
    }
}

private struct StaticGraphRelationLLMService: LLMService {
    let output: String

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}
