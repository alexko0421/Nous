import Foundation

final class GalaxyEdgeEngine {
    private let nodeStore: NodeStore
    private let vectorStore: VectorStore
    private let relationJudge: GalaxyRelationJudge
    private let telemetry: GalaxyRelationTelemetry?

    init(
        nodeStore: NodeStore,
        vectorStore: VectorStore,
        relationJudge: GalaxyRelationJudge,
        telemetry: GalaxyRelationTelemetry? = nil
    ) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
        self.relationJudge = relationJudge
        self.telemetry = telemetry
    }

    func generateSemanticEdges(
        for node: NousNode,
        threshold: Float = GalaxyRelationTuning.semanticThreshold
    ) throws {
        try nodeStore.deleteEdges(nodeId: node.id, type: .semantic)
        let neighbors = try vectorStore.findSemanticNeighbors(for: node, threshold: threshold)
        telemetry?.record(.relationCandidates(neighbors.count))
        let atomsByNodeId = try memoryAtomsBySourceNodeId(
            sourceNodeIds: [node.id] + neighbors.map(\.node.id)
        )
        let sourceAtoms = atomsByNodeId[node.id, default: []]

        for neighbor in neighbors {
            guard let verdict = relationJudge.judge(
                source: node,
                target: neighbor.node,
                similarity: neighbor.similarity,
                sourceAtoms: sourceAtoms,
                targetAtoms: atomsByNodeId[neighbor.node.id, default: []]
            ) else {
                continue
            }

            let edge = semanticEdge(
                source: node,
                target: neighbor.node,
                similarity: neighbor.similarity,
                verdict: verdict
            )
            try nodeStore.insertEdge(edge)
            telemetry?.record(.semanticEdgeWrite)
        }
    }

    func generateSemanticEdgesWithRefinement(
        for node: NousNode,
        threshold: Float = GalaxyRelationTuning.semanticThreshold,
        maxCandidates: Int = GalaxyRelationTuning.manualRefinementCandidateLimit
    ) async throws {
        try generateSemanticEdges(for: node, threshold: threshold)
        try await refineSemanticEdges(
            for: node,
            threshold: threshold,
            maxCandidates: maxCandidates
        )
    }

    func refineRelations(forNodeId nodeId: UUID) async throws {
        guard let node = try nodeStore.fetchNode(id: nodeId), node.embedding != nil else {
            return
        }

        try await refineSemanticEdges(
            for: node,
            maxCandidates: GalaxyRelationTuning.queuedRefinementCandidateLimit
        )
    }

    func refineSemanticEdges(
        for node: NousNode,
        threshold: Float = GalaxyRelationTuning.semanticThreshold,
        maxCandidates: Int = GalaxyRelationTuning.queuedRefinementCandidateLimit
    ) async throws {
        let neighbors = try vectorStore.findSemanticNeighbors(for: node, threshold: threshold)
        let atomsByNodeId = try memoryAtomsBySourceNodeId(
            sourceNodeIds: [node.id] + neighbors.map(\.node.id)
        )
        let sourceAtoms = atomsByNodeId[node.id, default: []]

        let candidates = Array(neighbors.prefix(maxCandidates))
        telemetry?.record(.refinedCandidates(candidates.count))

        for neighbor in candidates {
            let targetAtoms = atomsByNodeId[neighbor.node.id, default: []]
            guard let verdict = await relationJudge.judgeRefined(
                source: node,
                target: neighbor.node,
                similarity: neighbor.similarity,
                sourceAtoms: sourceAtoms,
                targetAtoms: targetAtoms
            ) else {
                continue
            }

            let edge = semanticEdge(
                source: node,
                target: neighbor.node,
                similarity: neighbor.similarity,
                verdict: verdict
            )
            try nodeStore.upsertEdge(edge)
            telemetry?.record(.semanticEdgeWrite)
        }
    }

    func generateSharedEdges(for node: NousNode) throws {
        guard let projectId = node.projectId else { return }
        try nodeStore.deleteEdges(nodeId: node.id, type: .shared)
        let siblings = try nodeStore.fetchNodes(projectId: projectId)
        var inserted = 0
        for sibling in siblings where sibling.id != node.id {
            let edge = NodeEdge(
                sourceId: node.id,
                targetId: sibling.id,
                strength: 0.3,
                type: .shared,
                confidence: 0.3,
                explanation: "These nodes belong to the same project."
            )
            try nodeStore.insertEdge(edge)
            inserted += 1
        }
        telemetry?.record(.sharedEdgeWrites(inserted))
    }

    func regenerateEdges(for node: NousNode) throws {
        try generateSemanticEdges(for: node)
        try generateSharedEdges(for: node)
    }

    func regenerateEdgesWithRefinement(for node: NousNode) async throws {
        try await generateSemanticEdgesWithRefinement(for: node)
        try generateSharedEdges(for: node)
    }

    private func semanticEdge(
        source: NousNode,
        target: NousNode,
        similarity: Float,
        verdict: GalaxyRelationVerdict
    ) -> NodeEdge {
        NodeEdge(
            sourceId: source.id,
            targetId: target.id,
            strength: similarity,
            type: .semantic,
            relationKind: verdict.relationKind,
            confidence: verdict.confidence,
            explanation: verdict.explanation,
            sourceEvidence: verdict.sourceEvidence,
            targetEvidence: verdict.targetEvidence,
            sourceAtomId: verdict.sourceAtomId,
            targetAtomId: verdict.targetAtomId
        )
    }

    private func memoryAtomsBySourceNodeId(sourceNodeIds: [UUID]) throws -> [UUID: [MemoryAtom]] {
        try nodeStore.fetchMemoryAtoms(sourceNodeIds: sourceNodeIds)
            .reduce(into: [UUID: [MemoryAtom]]()) { result, atom in
                guard let sourceNodeId = atom.sourceNodeId else { return }
                result[sourceNodeId, default: []].append(atom)
            }
    }
}
