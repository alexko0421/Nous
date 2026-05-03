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

    func testLayoutSpreadsDenseConstellationAcrossQuietCanvas() {
        let nodes = (0..<10).map { index in
            NousNode(type: .conversation, title: "Node \(index)")
        }

        let positions = GraphLayoutEngine().computeLayout(nodes: nodes, edges: [])
        let xs = positions.values.map(\.x)
        let ys = positions.values.map(\.y)
        let spanX = (xs.max() ?? 0) - (xs.min() ?? 0)
        let spanY = (ys.max() ?? 0) - (ys.min() ?? 0)

        XCTAssertGreaterThanOrEqual(max(spanX, spanY), 720)
    }

    func testDenseConnectedConstellationKeepsReadableSpacing() {
        let nodes = (0..<26).map { index in
            NousNode(type: .conversation, title: "Dense Node \(index)")
        }
        let hubId = nodes[0].id
        var edges: [NodeEdge] = nodes.dropFirst().map { node in
            NodeEdge(sourceId: hubId, targetId: node.id, strength: 0.92, type: .semantic)
        }

        for index in 1..<nodes.count {
            let nextIndex = index == nodes.count - 1 ? 1 : index + 1
            edges.append(NodeEdge(
                sourceId: nodes[index].id,
                targetId: nodes[nextIndex].id,
                strength: 0.68,
                type: .semantic
            ))
        }

        let positions = GraphLayoutEngine().computeLayout(nodes: nodes, edges: edges)

        XCTAssertGreaterThanOrEqual(minimumPairDistance(in: positions), 58)
        XCTAssertGreaterThanOrEqual(maxSpan(in: positions), 820)
    }

    func testDragRelaxationPullsConnectedNeighborWithoutDraggingUnrelatedNodes() throws {
        let draggedId = UUID()
        let connectedId = UUID()
        let unrelatedId = UUID()
        let edge = NodeEdge(sourceId: draggedId, targetId: connectedId, strength: 1.0, type: .semantic)
        let positions = [
            draggedId: GraphPosition(x: 0, y: 0),
            connectedId: GraphPosition(x: 80, y: 0),
            unrelatedId: GraphPosition(x: -140, y: 0)
        ]

        let relaxed = GraphLayoutEngine().relaxPositionsAfterDrag(
            draggedNodeId: draggedId,
            from: GraphPosition(x: 0, y: 0),
            to: GraphPosition(x: 100, y: 0),
            positions: positions,
            edges: [edge]
        )

        let dragged = try XCTUnwrap(relaxed[draggedId])
        let connected = try XCTUnwrap(relaxed[connectedId])
        let unrelated = try XCTUnwrap(relaxed[unrelatedId])
        let originalUnrelated = try XCTUnwrap(positions[unrelatedId])

        XCTAssertEqual(dragged.x, 100, accuracy: 0.001)
        XCTAssertGreaterThan(connected.x, 80)
        XCTAssertEqual(unrelated.x, originalUnrelated.x, accuracy: 0.001)
    }

    func testDragRelaxationPropagatesThroughConnectedChainWithDampedFalloff() throws {
        let draggedId = UUID()
        let directNeighborId = UUID()
        let secondDegreeNeighborId = UUID()
        let unrelatedId = UUID()
        let positions = [
            draggedId: GraphPosition(x: 0, y: 0),
            directNeighborId: GraphPosition(x: 90, y: 0),
            secondDegreeNeighborId: GraphPosition(x: 190, y: 0),
            unrelatedId: GraphPosition(x: -220, y: 0)
        ]
        let edges = [
            NodeEdge(sourceId: draggedId, targetId: directNeighborId, strength: 1.0, type: .semantic),
            NodeEdge(sourceId: directNeighborId, targetId: secondDegreeNeighborId, strength: 0.8, type: .semantic)
        ]

        let relaxed = GraphLayoutEngine().relaxPositionsAfterDrag(
            draggedNodeId: draggedId,
            from: GraphPosition(x: 0, y: 0),
            to: GraphPosition(x: 140, y: 0),
            positions: positions,
            edges: edges
        )

        let directNeighbor = try XCTUnwrap(relaxed[directNeighborId])
        let secondDegreeNeighbor = try XCTUnwrap(relaxed[secondDegreeNeighborId])
        let unrelated = try XCTUnwrap(relaxed[unrelatedId])

        XCTAssertGreaterThan(directNeighbor.x, 90)
        XCTAssertGreaterThan(secondDegreeNeighbor.x, 190)
        XCTAssertLessThan(secondDegreeNeighbor.x - 190, directNeighbor.x - 90)
        XCTAssertEqual(unrelated.x, -220, accuracy: 0.001)
    }

    func testSmallDragRunsLiveForceThroughWiderConnectedGraph() throws {
        let draggedId = UUID()
        let firstNeighborId = UUID()
        let secondNeighborId = UUID()
        let thirdNeighborId = UUID()
        let unrelatedId = UUID()
        let positions = [
            draggedId: GraphPosition(x: 0, y: 0),
            firstNeighborId: GraphPosition(x: 90, y: 0),
            secondNeighborId: GraphPosition(x: 180, y: 0),
            thirdNeighborId: GraphPosition(x: 270, y: 0),
            unrelatedId: GraphPosition(x: -220, y: 0)
        ]
        let edges = [
            NodeEdge(sourceId: draggedId, targetId: firstNeighborId, strength: 1.0, type: .semantic),
            NodeEdge(sourceId: firstNeighborId, targetId: secondNeighborId, strength: 0.9, type: .semantic),
            NodeEdge(sourceId: secondNeighborId, targetId: thirdNeighborId, strength: 0.8, type: .semantic)
        ]

        let relaxed = GraphLayoutEngine().relaxPositionsAfterDrag(
            draggedNodeId: draggedId,
            from: GraphPosition(x: 0, y: 0),
            to: GraphPosition(x: 14, y: 0),
            positions: positions,
            edges: edges
        )

        let firstNeighbor = try XCTUnwrap(relaxed[firstNeighborId])
        let secondNeighbor = try XCTUnwrap(relaxed[secondNeighborId])
        let thirdNeighbor = try XCTUnwrap(relaxed[thirdNeighborId])
        let unrelated = try XCTUnwrap(relaxed[unrelatedId])

        XCTAssertGreaterThan(firstNeighbor.x, 96)
        XCTAssertGreaterThan(secondNeighbor.x, 184)
        XCTAssertGreaterThan(thirdNeighbor.x, 272)
        XCTAssertEqual(unrelated.x, -220, accuracy: 0.001)
    }

    func testDragRelaxationLeavesDisconnectedEdgeComponentStill() throws {
        let draggedId = UUID()
        let connectedId = UUID()
        let remoteSourceId = UUID()
        let remoteTargetId = UUID()
        let positions = [
            draggedId: GraphPosition(x: 0, y: 0),
            connectedId: GraphPosition(x: 92, y: 0),
            remoteSourceId: GraphPosition(x: -260, y: -80),
            remoteTargetId: GraphPosition(x: -176, y: -80)
        ]
        let edges = [
            NodeEdge(sourceId: draggedId, targetId: connectedId, strength: 1.0, type: .semantic),
            NodeEdge(sourceId: remoteSourceId, targetId: remoteTargetId, strength: 0.9, type: .semantic)
        ]

        let relaxed = GraphLayoutEngine().relaxPositionsAfterDrag(
            draggedNodeId: draggedId,
            from: GraphPosition(x: 0, y: 0),
            to: GraphPosition(x: 36, y: 0),
            positions: positions,
            edges: edges
        )

        let connected = try XCTUnwrap(relaxed[connectedId])
        let remoteSource = try XCTUnwrap(relaxed[remoteSourceId])
        let remoteTarget = try XCTUnwrap(relaxed[remoteTargetId])

        XCTAssertGreaterThan(connected.x, 92)
        XCTAssertEqual(remoteSource.x, -260, accuracy: 0.001)
        XCTAssertEqual(remoteSource.y, -80, accuracy: 0.001)
        XCTAssertEqual(remoteTarget.x, -176, accuracy: 0.001)
        XCTAssertEqual(remoteTarget.y, -80, accuracy: 0.001)
    }

    private func minimumPairDistance(in positions: [UUID: GraphPosition]) -> Float {
        let values = Array(positions.values)
        guard values.count > 1 else { return 0 }

        var minimum = Float.greatestFiniteMagnitude
        for leftIndex in 0..<values.count {
            for rightIndex in (leftIndex + 1)..<values.count {
                let dx = values[leftIndex].x - values[rightIndex].x
                let dy = values[leftIndex].y - values[rightIndex].y
                minimum = min(minimum, sqrt(dx * dx + dy * dy))
            }
        }
        return minimum
    }

    private func maxSpan(in positions: [UUID: GraphPosition]) -> Float {
        let xs = positions.values.map(\.x)
        let ys = positions.values.map(\.y)
        return max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
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

    func testRefineSemanticEdgeUpgradesVectorEdgeWithConcreteLLMRelation() async throws {
        engine = GraphEngine(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            relationJudge: GalaxyRelationJudge(
                llmServiceProvider: {
                    StaticGraphRelationLLMService(output: """
                    {
                      "relation": "same_pattern",
                      "confidence": 0.86,
                      "explanation": "两段都在问 UI/UX 能不能成为产品成功的关键能力。",
                      "source_evidence": "未来 aui 设计师系咪一个好吃香嘅职位",
                      "target_evidence": "最终用户用嘅都係个 interface，所以 UI 靓唔靓、UX 好唔好",
                      "source_atom_id": null,
                      "target_atom_id": null
                    }
                    """)
                }
            )
        )
        var n1 = NousNode(
            type: .conversation,
            title: "UIUX 设计师嘅未来",
            content: "你觉得喺未来 aui 设计师系咪一个好吃香嘅职位呢。"
        )
        n1.embedding = [1.0, 0.0, 0.0]
        var n2 = NousNode(
            type: .conversation,
            title: "Direction 模式开场",
            content: "最终用户用嘅都係个 interface，所以 UI 靓唔靓、UX 好唔好，都係决定个 product 成功与否嘅关键。"
        )
        n2.embedding = [0.9, 0.1, 0.0]
        try nodeStore.insertNode(n1)
        try nodeStore.insertNode(n2)
        try engine.generateSemanticEdges(for: n1)
        let originalEdge = try XCTUnwrap(nodeStore.fetchEdges(nodeId: n1.id).first)
        XCTAssertEqual(originalEdge.relationKind, .topicSimilarity)

        let refinedEdge = try await engine.refineSemanticEdge(sourceId: n1.id, targetId: n2.id)

        XCTAssertEqual(refinedEdge?.id, originalEdge.id)
        XCTAssertEqual(refinedEdge?.relationKind, .samePattern)
        XCTAssertEqual(refinedEdge?.explanation, "两段都在问 UI/UX 能不能成为产品成功的关键能力。")
        let storedEdge = try XCTUnwrap(nodeStore.fetchEdges(nodeId: n1.id).first)
        XCTAssertEqual(storedEdge.id, originalEdge.id)
        XCTAssertEqual(storedEdge.relationKind, .samePattern)
    }

    func testRefineSemanticEdgeRemovesVectorEdgeWhenLLMFindsNoUsefulRelation() async throws {
        engine = GraphEngine(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            relationJudge: GalaxyRelationJudge(
                llmServiceProvider: {
                    StaticGraphRelationLLMService(output: """
                    {
                      "relation": "none",
                      "confidence": 0.92,
                      "explanation": "只是共同提到购物，不能构成有用关系。",
                      "source_evidence": "buy the shoes tomorrow right after class",
                      "target_evidence": "hung out around shopping/buying things",
                      "source_atom_id": null,
                      "target_atom_id": null
                    }
                    """)
                }
            )
        )
        var n1 = NousNode(type: .conversation, title: "Shoe decision", content: "Alex plans to buy the shoes tomorrow right after class.")
        n1.embedding = [1.0, 0.0, 0.0]
        var n2 = NousNode(type: .note, title: "Shopping hangout", content: "Alex and the Mexican girl previously hung out around shopping/buying things.")
        n2.embedding = [0.95, 0.05, 0.0]
        try nodeStore.insertNode(n1)
        try nodeStore.insertNode(n2)
        try engine.generateSemanticEdges(for: n1)
        XCTAssertEqual(try nodeStore.fetchEdges(nodeId: n1.id).count, 1)

        let refinedEdge = try await engine.refineSemanticEdge(sourceId: n1.id, targetId: n2.id)

        XCTAssertNil(refinedEdge)
        XCTAssertTrue(try nodeStore.fetchEdges(nodeId: n1.id).isEmpty)
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
