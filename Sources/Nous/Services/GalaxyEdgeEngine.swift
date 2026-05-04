import Foundation

final class GalaxyEdgeEngine {
    private let nodeStore: NodeStore
    private let vectorStore: VectorStore
    private let relationJudge: GalaxyRelationJudge
    private let connectionJudge: ConnectionJudge
    private let telemetry: GalaxyRelationTelemetry?

    init(
        nodeStore: NodeStore,
        vectorStore: VectorStore,
        relationJudge: GalaxyRelationJudge,
        connectionJudge: ConnectionJudge = ConnectionJudge(),
        telemetry: GalaxyRelationTelemetry? = nil
    ) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
        self.relationJudge = relationJudge
        self.connectionJudge = connectionJudge
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
            let rawVerdict = relationJudge.judge(
                source: node,
                target: neighbor.node,
                similarity: neighbor.similarity,
                sourceAtoms: sourceAtoms,
                targetAtoms: atomsByNodeId[neighbor.node.id, default: []]
            )
            let assessment = connectionJudge.assess(
                source: node,
                target: neighbor.node,
                similarity: neighbor.similarity,
                verdict: rawVerdict
            )
            guard assessment.decision == .accept, let verdict = assessment.verdict else {
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

    func refineSemanticEdge(sourceId: UUID, targetId: UUID) async throws -> NodeEdge? {
        guard let existingEdge = try semanticEdgeBetween(sourceId: sourceId, targetId: targetId) else {
            return nil
        }
        guard
            let source = try nodeStore.fetchNode(id: existingEdge.sourceId),
            let target = try nodeStore.fetchNode(id: existingEdge.targetId)
        else {
            return nil
        }

        let atomsByNodeId = try memoryAtomsBySourceNodeId(
            sourceNodeIds: [source.id, target.id]
        )
        let rawVerdict = await relationJudge.judgeRefined(
            source: source,
            target: target,
            similarity: existingEdge.strength,
            sourceAtoms: atomsByNodeId[source.id, default: []],
            targetAtoms: atomsByNodeId[target.id, default: []]
        )
        let assessment = connectionJudge.assess(
            source: source,
            target: target,
            similarity: existingEdge.strength,
            verdict: rawVerdict
        )
        guard assessment.decision == .accept, let verdict = assessment.verdict else {
            try nodeStore.deleteEdgeBetween(
                sourceId: existingEdge.sourceId,
                targetId: existingEdge.targetId,
                type: .semantic
            )
            return nil
        }

        let edge = semanticEdge(
            id: existingEdge.id,
            source: source,
            target: target,
            similarity: existingEdge.strength,
            verdict: verdict
        )
        try nodeStore.upsertEdge(edge)
        return edge
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
            let rawVerdict = await relationJudge.judgeRefined(
                source: node,
                target: neighbor.node,
                similarity: neighbor.similarity,
                sourceAtoms: sourceAtoms,
                targetAtoms: targetAtoms
            )
            let assessment = connectionJudge.assess(
                source: node,
                target: neighbor.node,
                similarity: neighbor.similarity,
                verdict: rawVerdict
            )
            guard assessment.decision == .accept, let verdict = assessment.verdict else {
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
        id: UUID = UUID(),
        source: NousNode,
        target: NousNode,
        similarity: Float,
        verdict: GalaxyRelationVerdict
    ) -> NodeEdge {
        NodeEdge(
            id: id,
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

    private func semanticEdgeBetween(sourceId: UUID, targetId: UUID) throws -> NodeEdge? {
        try nodeStore.fetchEdges(nodeId: sourceId).first { edge in
            edge.type == .semantic &&
            (
                (edge.sourceId == sourceId && edge.targetId == targetId) ||
                (edge.sourceId == targetId && edge.targetId == sourceId)
            )
        }
    }

    private func memoryAtomsBySourceNodeId(sourceNodeIds: [UUID]) throws -> [UUID: [MemoryAtom]] {
        try nodeStore.fetchMemoryAtoms(sourceNodeIds: sourceNodeIds)
            .reduce(into: [UUID: [MemoryAtom]]()) { result, atom in
                guard let sourceNodeId = atom.sourceNodeId else { return }
                result[sourceNodeId, default: []].append(atom)
            }
    }
}
