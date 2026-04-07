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
}
