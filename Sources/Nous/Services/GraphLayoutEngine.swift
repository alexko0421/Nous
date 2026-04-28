import Foundation

final class GraphLayoutEngine {
    func computeLayout(
        nodes: [NousNode],
        edges: [NodeEdge],
        iterations: Int = 180,
        repulsion: Float = 12000,
        attraction: Float = 0.004,
        damping: Float = 0.86
    ) -> [UUID: GraphPosition] {
        guard !nodes.isEmpty else { return [:] }

        var positions: [UUID: GraphPosition] = [:]
        var velocities: [UUID: GraphPosition] = [:]
        for node in nodes {
            positions[node.id] = GraphPosition(
                x: Float.random(in: -200...200),
                y: Float.random(in: -200...200)
            )
            velocities[node.id] = GraphPosition(x: 0, y: 0)
        }

        let adjacency = edges.map { edge in
            (edge.sourceId, edge.targetId, edge.strength)
        }

        for _ in 0..<iterations {
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

            for (sourceId, targetId, strength) in adjacency {
                guard positions[sourceId] != nil, positions[targetId] != nil else { continue }
                let pA = positions[sourceId]!
                let pB = positions[targetId]!
                let dx = pA.x - pB.x
                let dy = pA.y - pB.y
                let fx = attraction * strength * dx
                let fy = attraction * strength * dy
                velocities[sourceId]!.x -= fx
                velocities[sourceId]!.y -= fy
                velocities[targetId]!.x += fx
                velocities[targetId]!.y += fy
            }

            for node in nodes {
                velocities[node.id]!.x *= damping
                velocities[node.id]!.y *= damping
                positions[node.id]!.x += velocities[node.id]!.x
                positions[node.id]!.y += velocities[node.id]!.y
            }
        }

        return normalize(positions)
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
