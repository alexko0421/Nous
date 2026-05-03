import Foundation

struct GraphPosition {
    var x: Float
    var y: Float
}

final class GraphEngine: GalaxyRelationRefining {
    private let nodeStore: NodeStore
    private let layoutEngine: GraphLayoutEngine
    private let edgeEngine: GalaxyEdgeEngine

    init(
        nodeStore: NodeStore,
        vectorStore: VectorStore,
        relationJudge: GalaxyRelationJudge = GalaxyRelationJudge(),
        layoutEngine: GraphLayoutEngine = GraphLayoutEngine(),
        telemetry: GalaxyRelationTelemetry? = nil
    ) {
        self.nodeStore = nodeStore
        self.layoutEngine = layoutEngine
        self.edgeEngine = GalaxyEdgeEngine(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            relationJudge: relationJudge,
            telemetry: telemetry
        )
    }

    func computeLayout(
        iterations: Int = 280,
        repulsion: Float = 64000,
        attraction: Float = 0.010,
        damping: Float = 0.78
    ) throws -> [UUID: GraphPosition] {
        try layoutEngine.computeLayout(
            nodes: nodeStore.fetchAllNodes(),
            edges: nodeStore.fetchAllEdges(),
            iterations: iterations,
            repulsion: repulsion,
            attraction: attraction,
            damping: damping
        )
    }

    func generateSemanticEdges(
        for node: NousNode,
        threshold: Float = GalaxyRelationTuning.semanticThreshold
    ) throws {
        try edgeEngine.generateSemanticEdges(for: node, threshold: threshold)
    }

    func generateSemanticEdgesWithRefinement(
        for node: NousNode,
        threshold: Float = GalaxyRelationTuning.semanticThreshold,
        maxCandidates: Int = GalaxyRelationTuning.manualRefinementCandidateLimit
    ) async throws {
        try await edgeEngine.generateSemanticEdgesWithRefinement(
            for: node,
            threshold: threshold,
            maxCandidates: maxCandidates
        )
    }

    func refineRelations(forNodeId nodeId: UUID) async throws {
        try await edgeEngine.refineRelations(forNodeId: nodeId)
    }

    func refineSemanticEdge(sourceId: UUID, targetId: UUID) async throws -> NodeEdge? {
        try await edgeEngine.refineSemanticEdge(sourceId: sourceId, targetId: targetId)
    }

    func refineSemanticEdges(
        for node: NousNode,
        threshold: Float = GalaxyRelationTuning.semanticThreshold,
        maxCandidates: Int = GalaxyRelationTuning.queuedRefinementCandidateLimit
    ) async throws {
        try await edgeEngine.refineSemanticEdges(
            for: node,
            threshold: threshold,
            maxCandidates: maxCandidates
        )
    }

    func generateSharedEdges(for node: NousNode) throws {
        try edgeEngine.generateSharedEdges(for: node)
    }

    func regenerateEdges(for node: NousNode) throws {
        try edgeEngine.regenerateEdges(for: node)
    }

    func regenerateEdgesWithRefinement(for node: NousNode) async throws {
        try await edgeEngine.regenerateEdgesWithRefinement(for: node)
    }
}
