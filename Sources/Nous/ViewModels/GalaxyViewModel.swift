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

    private let nodeStore: NodeStore
    private let graphEngine: GraphEngine

    init(nodeStore: NodeStore, graphEngine: GraphEngine) {
        self.nodeStore = nodeStore
        self.graphEngine = graphEngine
    }

    func load() {
        isLoading = true
        Task {
            do {
                // Fetch nodes (filtered by project if set)
                let fetchedNodes: [NousNode]
                if let projectId = filterProjectId {
                    fetchedNodes = try nodeStore.fetchNodes(projectId: projectId)
                } else {
                    fetchedNodes = try nodeStore.fetchAllNodes()
                }

                // Fetch all edges and filter to visible nodes only
                let allEdges = try nodeStore.fetchAllEdges()
                let visibleIds = Set(fetchedNodes.map { $0.id })
                let filteredEdges = allEdges.filter {
                    visibleIds.contains($0.sourceId) && visibleIds.contains($0.targetId)
                }

                // Compute layout
                let allPositions = try graphEngine.computeLayout()

                // Filter positions to visible nodes
                let filteredPositions = allPositions.filter { visibleIds.contains($0.key) }

                await MainActor.run {
                    self.nodes = fetchedNodes
                    self.edges = filteredEdges
                    self.positions = filteredPositions
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
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
}
