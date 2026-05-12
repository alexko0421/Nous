import Foundation
import Observation

@Observable
final class GalaxyViewModel {
    var nodes: [NousNode] = []
    var edges: [NodeEdge] = []
    var positions: [UUID: GraphPosition] = [:]
    var selectedNodeId: UUID?
    var filterProjectId: UUID?
    var isLoading: Bool = false
    private var refiningEdgeIds: Set<UUID> = []

    private let nodeStore: NodeStore
    private let graphEngine: GraphEngine
    /// Phase A galaxy feedback ledger — see
    /// docs/superpowers/specs/2026-05-09-edge-inference-feedback-ledger-design.md.
    /// `feedbackStore` is read by the inspector ThumbFeedbackView via
    /// `feedback(for:)` and written via `upsertEdgeFeedback(...)`;
    /// `traceStore` provides the telemetry strip via `telemetry(for:)`.
    private let feedbackStore: EdgeFeedbackStore
    private let traceStore: EdgeJudgeTraceStore

    init(nodeStore: NodeStore, graphEngine: GraphEngine) {
        self.nodeStore = nodeStore
        self.graphEngine = graphEngine
        self.feedbackStore = EdgeFeedbackStore(nodeStore: nodeStore)
        self.traceStore = EdgeJudgeTraceStore(nodeStore: nodeStore)
    }

    func feedback(for edge: NodeEdge) -> EdgeFeedbackRow? {
        try? feedbackStore.fetch(
            sourceId: edge.sourceId,
            targetId: edge.targetId,
            relationKind: edge.relationKind.rawValue
        )
    }

    func telemetry(for edge: NodeEdge) -> TelemetryStrip? {
        guard let trace = try? traceStore.latest(sourceId: edge.sourceId, targetId: edge.targetId) else {
            return nil
        }
        let priorCount = feedback(for: edge)?.verdictCount ?? 0
        return TelemetryStrip(
            similarity: trace.similarity,
            judgePath: trace.judgePath,
            confidence: trace.confidence,
            judgedAt: trace.judgedAt,
            priorVerdictCount: priorCount
        )
    }

    func upsertEdgeFeedback(edge: NodeEdge, verdict: ThumbVerdict, note: String) {
        try? feedbackStore.upsert(
            sourceId: edge.sourceId,
            targetId: edge.targetId,
            relationKind: edge.relationKind.rawValue,
            verdict: verdict,
            note: note.isEmpty ? nil : note
        )
    }

    func load() {
        isLoading = true
        Task {
            do {
                let snapshot = try loadSnapshot()
                await MainActor.run {
                    self.apply(snapshot)
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }

    @discardableResult
    func refineRelationship(edge: NodeEdge?) -> Task<Void, Never>? {
        guard let edge, shouldRefineOnDemand(edge), !refiningEdgeIds.contains(edge.id) else {
            return nil
        }

        let edgeId = edge.id
        refiningEdgeIds.insert(edgeId)

        return Task { [weak self] in
            guard let self else { return }
            do {
                let refinedEdge = try await graphEngine.refineSemanticEdge(
                    sourceId: edge.sourceId,
                    targetId: edge.targetId
                )
                let snapshot = try loadSnapshot()
                await MainActor.run {
                    self.apply(snapshot)
                    if let refinedEdge, self.canDisplayEdge(refinedEdge) {
                        self.replaceOrAppendEdge(refinedEdge)
                    }
                    self.refiningEdgeIds.remove(edgeId)
                }
            } catch {
                await MainActor.run {
                    self.refiningEdgeIds.remove(edgeId)
                }
            }
        }
    }

    func isRefining(edgeId: UUID) -> Bool {
        refiningEdgeIds.contains(edgeId)
    }

    func updateNodePosition(_ nodeId: UUID, x: Float, y: Float) {
        positions[nodeId] = GraphPosition(x: x, y: y)
    }

    func nodeForId(_ id: UUID) -> NousNode? {
        nodes.first { $0.id == id }
    }

    var selectedNode: NousNode? {
        guard let selectedNodeId else { return nil }
        return nodeForId(selectedNodeId)
    }

    var selectedNodeEdges: [NodeEdge] {
        guard let selectedNodeId else { return [] }
        return edges
            .filter { $0.sourceId == selectedNodeId || $0.targetId == selectedNodeId }
            .sorted { lhs, rhs in
                edgeRank(lhs) == edgeRank(rhs)
                    ? lhs.confidence > rhs.confidence
                    : edgeRank(lhs) < edgeRank(rhs)
            }
    }

    func connectedNode(for edge: NodeEdge) -> NousNode? {
        guard let selectedNodeId else { return nil }
        let connectedId = edge.sourceId == selectedNodeId ? edge.targetId : edge.sourceId
        return nodeForId(connectedId)
    }

    private func edgeRank(_ edge: NodeEdge) -> Int {
        switch edge.type {
        case .manual:
            return 3
        case .shared:
            return 4
        case .semantic:
            return relationRank(edge.relationKind)
        }
    }

    private func relationRank(_ relationKind: GalaxyRelationKind) -> Int {
        switch relationKind {
        case .samePattern:
            return 0
        case .tension, .contradicts:
            return 1
        case .supports, .causeEffect:
            return 2
        case .topicSimilarity:
            return 3
        }
    }

    private func shouldRefineOnDemand(_ edge: NodeEdge) -> Bool {
        guard edge.type == .semantic else { return false }

        if edge.relationKind == .topicSimilarity {
            return true
        }

        if edge.sourceAtomId != nil || edge.targetAtomId != nil {
            return !GalaxyExplanationQuality.hasUsefulChineseExplanation(edge.explanation)
                || !GalaxyExplanationQuality.containsCJK(edge.sourceEvidence ?? "")
                || !GalaxyExplanationQuality.containsCJK(edge.targetEvidence ?? "")
        }

        return !GalaxyExplanationQuality.hasUsefulChineseExplanation(edge.explanation)
    }

    private struct Snapshot {
        let nodes: [NousNode]
        let edges: [NodeEdge]
        let positions: [UUID: GraphPosition]
    }

    private func loadSnapshot() throws -> Snapshot {
        let fetchedNodes: [NousNode]
        if let projectId = filterProjectId {
            fetchedNodes = try nodeStore.fetchNodes(projectId: projectId)
        } else {
            fetchedNodes = try nodeStore.fetchAllNodes()
        }

        let visibleIds = Set(fetchedNodes.map(\.id))
        let filteredEdges = try nodeStore.fetchAllEdges().filter {
            visibleIds.contains($0.sourceId) && visibleIds.contains($0.targetId)
        }
        let filteredPositions = try graphEngine.computeLayout().filter {
            visibleIds.contains($0.key)
        }

        return Snapshot(
            nodes: fetchedNodes,
            edges: filteredEdges,
            positions: filteredPositions
        )
    }

    private func apply(_ snapshot: Snapshot) {
        nodes = snapshot.nodes
        edges = snapshot.edges
        // Preserve any user-dragged positions (already in self.positions) for
        // nodes that still exist; only fall back to the freshly computed
        // layout for newly appearing nodes. Without this, every snapshot
        // reload (e.g. after refineRelationship) would snap dragged nodes
        // back to the force-simulated positions and look unstable.
        let visibleIds = Set(snapshot.nodes.map(\.id))
        var merged: [UUID: GraphPosition] = [:]
        for id in visibleIds {
            merged[id] = positions[id] ?? snapshot.positions[id]
        }
        positions = merged
    }

    private func replaceOrAppendEdge(_ edge: NodeEdge) {
        if let existingIndex = edges.firstIndex(where: { existingEdge in
            existingEdge.id == edge.id || sameEdgeEndpoints(existingEdge, edge)
        }) {
            edges[existingIndex] = edge
        } else {
            edges.append(edge)
        }
    }

    private func canDisplayEdge(_ edge: NodeEdge) -> Bool {
        let nodeIds = Set(nodes.map(\.id))
        return nodeIds.contains(edge.sourceId) && nodeIds.contains(edge.targetId)
    }

    private func sameEdgeEndpoints(_ lhs: NodeEdge, _ rhs: NodeEdge) -> Bool {
        lhs.type == rhs.type &&
            (
                (lhs.sourceId == rhs.sourceId && lhs.targetId == rhs.targetId) ||
                (lhs.sourceId == rhs.targetId && lhs.targetId == rhs.sourceId)
            )
    }
}
