import Foundation
import Accelerate

struct GraphPosition {
    var x: Float
    var y: Float
}

final class GraphEngine {
    private let nodeStore: NodeStore
    private let vectorStore: VectorStore

    init(nodeStore: NodeStore, vectorStore: VectorStore) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
    }

    // MARK: - Force-Directed Layout

    /// Compute force-directed layout for all nodes. Returns positions keyed by node ID.
    func computeLayout(
        iterations: Int = 180,
        repulsion: Float = 12000,
        attraction: Float = 0.004,
        damping: Float = 0.86
    ) throws -> [UUID: GraphPosition] {
        let nodes = try nodeStore.fetchAllNodes()
        let edges = try nodeStore.fetchAllEdges()
        guard !nodes.isEmpty else { return [:] }

        // Initialize random positions
        var positions: [UUID: GraphPosition] = [:]
        var velocities: [UUID: GraphPosition] = [:]
        for node in nodes {
            positions[node.id] = GraphPosition(
                x: Float.random(in: -200...200),
                y: Float.random(in: -200...200)
            )
            velocities[node.id] = GraphPosition(x: 0, y: 0)
        }

        // Build adjacency for attraction
        var adjacency: [(UUID, UUID, Float)] = []
        for edge in edges {
            adjacency.append((edge.sourceId, edge.targetId, edge.strength))
        }

        for _ in 0..<iterations {
            // Repulsion between all pairs
            for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count {
                    let idA = nodes[i].id
                    let idB = nodes[j].id
                    guard let pA = positions[idA], let pB = positions[idB] else { continue }
                    let dx = pA.x - pB.x
                    let dy = pA.y - pB.y
                    let distSq = max(dx * dx + dy * dy, 1.0)
                    let force = repulsion / distSq
                    let dist = sqrt(distSq)
                    let fx = force * dx / dist
                    let fy = force * dy / dist
                    velocities[idA]!.x += fx
                    velocities[idA]!.y += fy
                    velocities[idB]!.x -= fx
                    velocities[idB]!.y -= fy
                }
            }

            // Attraction along edges
            for (srcId, tgtId, strength) in adjacency {
                guard positions[srcId] != nil, positions[tgtId] != nil else { continue }
                let pA = positions[srcId]!
                let pB = positions[tgtId]!
                let dx = pA.x - pB.x
                let dy = pA.y - pB.y
                let fx = attraction * strength * dx
                let fy = attraction * strength * dy
                velocities[srcId]!.x -= fx
                velocities[srcId]!.y -= fy
                velocities[tgtId]!.x += fx
                velocities[tgtId]!.y += fy
            }

            // Apply velocity with damping
            for node in nodes {
                velocities[node.id]!.x *= damping
                velocities[node.id]!.y *= damping
                positions[node.id]!.x += velocities[node.id]!.x
                positions[node.id]!.y += velocities[node.id]!.y
            }
        }

        return normalize(positions)
    }

    // MARK: - Edge Generation

    func generateSemanticEdges(for node: NousNode, threshold: Float = 0.75) throws {
        try nodeStore.deleteEdges(nodeId: node.id, type: .semantic)
        let neighbors = try vectorStore.findSemanticNeighbors(for: node, threshold: threshold)
        for neighbor in neighbors {
            let edge = NodeEdge(
                sourceId: node.id,
                targetId: neighbor.node.id,
                strength: neighbor.similarity,
                type: .semantic
            )
            try nodeStore.insertEdge(edge)
        }
    }

    func regenerateEdges(for node: NousNode) throws {
        try generateSemanticEdges(for: node)
    }

    private func normalize(_ positions: [UUID: GraphPosition]) -> [UUID: GraphPosition] {
        guard
            let minX = positions.values.map(\.x).min(),
            let maxX = positions.values.map(\.x).max(),
            let minY = positions.values.map(\.y).min(),
            let maxY = positions.values.map(\.y).max()
        else {
            return positions
        }

        let width = max(maxX - minX, 1)
        let height = max(maxY - minY, 1)
        let scale = min(1.35, 640 / max(width, height))
        let centerX = (minX + maxX) * 0.5
        let centerY = (minY + maxY) * 0.5

        return positions.mapValues { position in
            GraphPosition(
                x: (position.x - centerX) * scale,
                y: (position.y - centerY) * scale
            )
        }
    }
}
