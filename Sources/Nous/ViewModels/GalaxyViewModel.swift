import Foundation
import Observation

struct GalaxyProjectSummary: Identifiable {
    let project: Project
    let nodeCount: Int
    let conversationCount: Int
    let noteCount: Int
    let lastUpdatedAt: Date?

    var id: UUID { project.id }
}

struct GalaxyConnection: Identifiable {
    let edge: NodeEdge
    let node: NousNode
    let project: Project?

    var id: UUID { node.id }
}

@Observable
final class GalaxyViewModel {
    var nodes: [NousNode] = []
    var edges: [NodeEdge] = []
    var positions: [UUID: GraphPosition] = [:]
    var selectedNodeId: UUID?
    var filterProjectId: UUID?
    var isLoading: Bool = false
    var projects: [Project] = []
    var projectSummaries: [GalaxyProjectSummary] = []

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
                let allProjects = try nodeStore.fetchAllProjects()
                let allNodes = try nodeStore.fetchAllNodes()
                let fetchedNodes: [NousNode]
                if let projectId = filterProjectId {
                    fetchedNodes = allNodes.filter { $0.projectId == projectId }
                } else {
                    fetchedNodes = allNodes
                }

                let allEdges = try nodeStore.fetchAllEdges()
                let visibleIds = Set(fetchedNodes.map { $0.id })
                let filteredEdges = allEdges.filter {
                    visibleIds.contains($0.sourceId) && visibleIds.contains($0.targetId)
                }

                let allPositions = try graphEngine.computeLayout(seedPositions: positions)
                let filteredPositions = allPositions.filter { visibleIds.contains($0.key) }
                let nextSelectedNodeId = selectedNodeId.flatMap { visibleIds.contains($0) ? $0 : nil }
                let projectSummaries = Self.makeProjectSummaries(
                    projects: allProjects,
                    nodes: allNodes
                )

                await MainActor.run {
                    self.projects = allProjects
                    self.projectSummaries = projectSummaries
                    self.nodes = fetchedNodes
                    self.edges = filteredEdges
                    self.positions = filteredPositions
                    self.selectedNodeId = nextSelectedNodeId
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

    func setProjectFilter(_ projectId: UUID?) {
        guard filterProjectId != projectId else { return }
        filterProjectId = projectId
        selectedNodeId = nil
        load()
    }

    func selectNode(_ id: UUID?) {
        selectedNodeId = id
    }

    func nodeForId(_ id: UUID) -> NousNode? {
        nodes.first { $0.id == id }
    }

    func projectForId(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    var selectedNode: NousNode? {
        selectedNodeId.flatMap(nodeForId)
    }

    var selectedProject: Project? {
        projectForId(filterProjectId)
    }

    var visibleConversationCount: Int {
        nodes.filter { $0.type == .conversation }.count
    }

    var visibleNoteCount: Int {
        nodes.filter { $0.type == .note }.count
    }

    var selectedConnections: [GalaxyConnection] {
        guard let selectedNodeId else { return [] }

        return edges
            .compactMap { edge -> GalaxyConnection? in
                let otherNodeId: UUID
                if edge.sourceId == selectedNodeId {
                    otherNodeId = edge.targetId
                } else if edge.targetId == selectedNodeId {
                    otherNodeId = edge.sourceId
                } else {
                    return nil
                }

                guard let node = nodeForId(otherNodeId) else { return nil }
                return GalaxyConnection(
                    edge: edge,
                    node: node,
                    project: projectForId(node.projectId)
                )
            }
            .sorted { lhs, rhs in
                if lhs.edge.type == rhs.edge.type {
                    return lhs.edge.strength > rhs.edge.strength
                }
                return edgeRank(lhs.edge.type) < edgeRank(rhs.edge.type)
            }
    }

    private static func makeProjectSummaries(
        projects: [Project],
        nodes: [NousNode]
    ) -> [GalaxyProjectSummary] {
        let groupedNodes = Dictionary(grouping: nodes) { $0.projectId }

        return projects.map { project in
            let projectNodes = groupedNodes[project.id] ?? []
            return GalaxyProjectSummary(
                project: project,
                nodeCount: projectNodes.count,
                conversationCount: projectNodes.filter { $0.type == .conversation }.count,
                noteCount: projectNodes.filter { $0.type == .note }.count,
                lastUpdatedAt: projectNodes.map(\.updatedAt).max()
            )
        }
        .sorted { lhs, rhs in
            let lhsDate = lhs.lastUpdatedAt ?? lhs.project.createdAt
            let rhsDate = rhs.lastUpdatedAt ?? rhs.project.createdAt
            return lhsDate > rhsDate
        }
    }

    private func edgeRank(_ type: EdgeType) -> Int {
        switch type {
        case .manual: return 0
        case .semantic: return 1
        }
    }
}
