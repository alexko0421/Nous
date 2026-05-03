import XCTest
@testable import Nous

final class GalaxyViewModelTests: XCTestCase {
    func testRefineRelationshipRefreshesEdgesAfterOnDemandReasoning() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let graphEngine = GraphEngine(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            relationJudge: GalaxyRelationJudge(
                llmServiceProvider: {
                    StaticGalaxyViewRelationLLMService(output: """
                    {
                      "relation": "same_pattern",
                      "confidence": 0.86,
                      "explanation": "两段都在问 UI/UX 能不能成为产品成功的关键能力。",
                      "source_evidence": "未来 aui 设计师系咪一个好吃香嘅职位",
                      "target_evidence": "最终用户用嘅都係个 interface",
                      "source_atom_id": null,
                      "target_atom_id": null
                    }
                    """)
                }
            )
        )
        var source = NousNode(
            type: .conversation,
            title: "UIUX 设计师嘅未来",
            content: "你觉得喺未来 aui 设计师系咪一个好吃香嘅职位呢。"
        )
        source.embedding = [1.0, 0.0, 0.0]
        var target = NousNode(
            type: .conversation,
            title: "Direction 模式开场",
            content: "最终用户用嘅都係个 interface，所以 UI 靓唔靓、UX 好唔好，都係决定个 product 成功与否嘅关键。"
        )
        target.embedding = [0.9, 0.1, 0.0]
        try nodeStore.insertNode(source)
        try nodeStore.insertNode(target)
        try graphEngine.generateSemanticEdges(for: source)
        let originalEdge = try XCTUnwrap(nodeStore.fetchEdges(nodeId: source.id).first)

        let viewModel = GalaxyViewModel(nodeStore: nodeStore, graphEngine: graphEngine)
        viewModel.nodes = [source, target]
        viewModel.edges = [originalEdge]
        viewModel.positions = [
            source.id: GraphPosition(x: 0, y: 0),
            target.id: GraphPosition(x: 100, y: 0)
        ]

        let task = try XCTUnwrap(viewModel.refineRelationship(edge: originalEdge))
        XCTAssertTrue(viewModel.isRefining(edgeId: originalEdge.id))

        await task.value

        XCTAssertFalse(viewModel.isRefining(edgeId: originalEdge.id))
        XCTAssertEqual(viewModel.edges.first?.id, originalEdge.id)
        XCTAssertEqual(viewModel.edges.first?.relationKind, .samePattern)
        XCTAssertEqual(viewModel.edges.first?.explanation, "两段都在问 UI/UX 能不能成为产品成功的关键能力。")
    }

    func testRefineRelationshipRunsForAtomBackedEdgeWithEnglishEvidence() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let graphEngine = GraphEngine(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            relationJudge: GalaxyRelationJudge(
                llmServiceProvider: {
                    StaticGalaxyViewRelationLLMService(output: """
                    {
                      "relation": "same_pattern",
                      "confidence": 0.88,
                      "explanation": "两段都在描述 Alex 用哲学和长期方向感来重新判断未来选择。",
                      "source_evidence": "第一段记录 Alex 对斯多葛主义特别感兴趣。",
                      "target_evidence": "第二段记录 Alex 对当前 app 的方向和目的感到迷失。",
                      "source_atom_id": null,
                      "target_atom_id": null
                    }
                    """)
                }
            )
        )
        var source = NousNode(
            type: .conversation,
            title: "未来系咪文科生嘅天下",
            content: "Alex is particularly interested in Stoicism."
        )
        source.embedding = [1.0, 0.0, 0.0]
        var target = NousNode(
            type: .conversation,
            title: "Direction 模式开场",
            content: "Alex feels confused/lost about the direction and purpose of the app he is currently building."
        )
        target.embedding = [0.9, 0.1, 0.0]
        try nodeStore.insertNode(source)
        try nodeStore.insertNode(target)

        let atomSource = MemoryAtom(
            type: .pattern,
            statement: "Alex is particularly interested in Stoicism.",
            scope: .conversation,
            sourceNodeId: source.id
        )
        let atomTarget = MemoryAtom(
            type: .insight,
            statement: "Alex feels confused/lost about the direction and purpose of the app he is currently building.",
            scope: .conversation,
            sourceNodeId: target.id
        )
        try nodeStore.insertMemoryAtom(atomSource)
        try nodeStore.insertMemoryAtom(atomTarget)
        try graphEngine.generateSemanticEdges(for: source)
        let originalEdge = try XCTUnwrap(nodeStore.fetchEdges(nodeId: source.id).first)
        XCTAssertNotNil(originalEdge.sourceAtomId)
        XCTAssertFalse(GalaxyExplanationQuality.containsCJK(originalEdge.sourceEvidence ?? ""))

        let viewModel = GalaxyViewModel(nodeStore: nodeStore, graphEngine: graphEngine)
        viewModel.nodes = [source, target]
        viewModel.edges = [originalEdge]
        viewModel.positions = [
            source.id: GraphPosition(x: 0, y: 0),
            target.id: GraphPosition(x: 100, y: 0)
        ]

        let task = try XCTUnwrap(viewModel.refineRelationship(edge: originalEdge))

        await task.value

        XCTAssertEqual(viewModel.edges.first?.explanation, "两段都在描述 Alex 用哲学和长期方向感来重新判断未来选择。")
        XCTAssertEqual(viewModel.edges.first?.sourceEvidence, "第一段记录 Alex 对斯多葛主义特别感兴趣。")
    }
}

private struct StaticGalaxyViewRelationLLMService: LLMService {
    let output: String

    func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }
}
