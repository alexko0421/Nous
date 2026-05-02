import Foundation

final class GraphLayoutEngine {
    func computeLayout(
        nodes: [NousNode],
        edges: [NodeEdge],
        iterations: Int = 280,
        repulsion: Float = 64000,
        attraction: Float = 0.010,
        damping: Float = 0.78,
        minimumNodeDistance: Float = 84,
        targetSpan: Float = 1040
    ) -> [UUID: GraphPosition] {
        guard !nodes.isEmpty else { return [:] }

        var positions: [UUID: GraphPosition] = [:]
        var velocities: [UUID: GraphPosition] = [:]
        for (index, node) in nodes.enumerated() {
            positions[node.id] = initialPosition(for: node, index: index, count: nodes.count)
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
                let dist = max(sqrt(dx * dx + dy * dy), 1)
                let targetDistance = preferredEdgeDistance(for: strength)
                let displacement = dist - targetDistance
                let force = attraction * strength.clamped(to: 0.2...1.0) * displacement
                let fx = force * dx / dist
                let fy = force * dy / dist
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

            if !nodes.isEmpty && iterations > 0 {
                positions = separateClosePairs(
                    positions,
                    nodes: nodes,
                    minimumDistance: minimumNodeDistance,
                    passes: 1
                )
            }
        }

        let expanded = spreadCrowdedComponents(positions, nodes: nodes, edges: edges)
        let normalized = normalize(expanded, targetSpan: targetSpan)
        return separateClosePairs(
            normalized,
            nodes: nodes,
            minimumDistance: minimumNodeDistance * 0.74,
            passes: 8
        )
    }

    func relaxPositionsAfterDrag(
        draggedNodeId: UUID,
        from previousPosition: GraphPosition,
        to newPosition: GraphPosition,
        positions: [UUID: GraphPosition],
        edges: [NodeEdge],
        neighborPull: Float = 0.28,
        minimumDistance: Float = 54
    ) -> [UUID: GraphPosition] {
        var relaxed = positions
        relaxed[draggedNodeId] = newPosition

        let deltaX = newPosition.x - previousPosition.x
        let deltaY = newPosition.y - previousPosition.y
        guard abs(deltaX) > 0.001 || abs(deltaY) > 0.001 else { return relaxed }

        for (neighborId, strength) in connectedNeighbors(to: draggedNodeId, edges: edges) {
            guard var neighborPosition = relaxed[neighborId] else { continue }
            let pull = neighborPull * strength.clamped(to: 0.25...1.0)
            neighborPosition.x += deltaX * pull
            neighborPosition.y += deltaY * pull
            relaxed[neighborId] = positionBySeparating(
                neighborPosition,
                from: newPosition,
                minimumDistance: minimumDistance
            )
        }

        return relaxed
    }

    private func initialPosition(for node: NousNode, index: Int, count: Int) -> GraphPosition {
        let goldenAngle: Float = 2.3999631
        let ring = Float(index + 1) / max(Float(count), 1)
        let radius = 140 + sqrt(ring) * 240
        let jitter = stableUnitValue(for: node.id) * 0.42
        let angle = Float(index) * goldenAngle + jitter

        return GraphPosition(
            x: cos(angle) * radius,
            y: sin(angle) * radius
        )
    }

    private func stableUnitValue(for id: UUID) -> Float {
        let total = id.uuidString.unicodeScalars.reduce(0) { partial, scalar in
            partial + Int(scalar.value)
        }
        return Float(total % 1000) / 1000
    }

    private func preferredEdgeDistance(for strength: Float) -> Float {
        270 - strength.clamped(to: 0...1) * 38
    }

    private func connectedNeighbors(to nodeId: UUID, edges: [NodeEdge]) -> [(UUID, Float)] {
        var strengthsByNodeId: [UUID: Float] = [:]

        for edge in edges {
            let neighborId: UUID?
            if edge.sourceId == nodeId {
                neighborId = edge.targetId
            } else if edge.targetId == nodeId {
                neighborId = edge.sourceId
            } else {
                neighborId = nil
            }

            guard let neighborId else { continue }
            strengthsByNodeId[neighborId] = max(strengthsByNodeId[neighborId, default: 0], edge.strength)
        }

        return strengthsByNodeId.map { ($0.key, $0.value) }
    }

    private func positionBySeparating(
        _ position: GraphPosition,
        from anchor: GraphPosition,
        minimumDistance: Float
    ) -> GraphPosition {
        let dx = position.x - anchor.x
        let dy = position.y - anchor.y
        let distance = sqrt(dx * dx + dy * dy)
        guard distance > 0.001, distance < minimumDistance else { return position }

        let push = minimumDistance - distance
        return GraphPosition(
            x: position.x + (dx / distance) * push,
            y: position.y + (dy / distance) * push
        )
    }

    private func spreadCrowdedComponents(
        _ positions: [UUID: GraphPosition],
        nodes: [NousNode],
        edges: [NodeEdge]
    ) -> [UUID: GraphPosition] {
        var expanded = positions

        for component in connectedComponents(nodes: nodes, edges: edges) where component.count >= 6 {
            let ids = Set(component)
            let componentPositions = expanded.filter { ids.contains($0.key) }
            let span = maxSpan(in: componentPositions)
            let desiredSpan = min(980, max(420, sqrt(Float(component.count)) * 168))
            guard span > 1, span < desiredSpan else { continue }

            let scale = min(desiredSpan / span, 2.65)
            let center = center(of: componentPositions)
            for id in component {
                guard let position = expanded[id] else { continue }
                expanded[id] = GraphPosition(
                    x: center.x + (position.x - center.x) * scale,
                    y: center.y + (position.y - center.y) * scale
                )
            }
        }

        return expanded
    }

    private func separateClosePairs(
        _ positions: [UUID: GraphPosition],
        nodes: [NousNode],
        minimumDistance: Float,
        passes: Int
    ) -> [UUID: GraphPosition] {
        var adjusted = positions
        guard nodes.count > 1 else { return adjusted }

        for _ in 0..<passes {
            for leftIndex in 0..<nodes.count {
                for rightIndex in (leftIndex + 1)..<nodes.count {
                    let leftId = nodes[leftIndex].id
                    let rightId = nodes[rightIndex].id
                    guard
                        var left = adjusted[leftId],
                        var right = adjusted[rightId]
                    else { continue }

                    var dx = left.x - right.x
                    var dy = left.y - right.y
                    var distance = sqrt(dx * dx + dy * dy)
                    if distance < 0.001 {
                        let angle = Float(leftIndex + rightIndex + 1) * 1.618
                        dx = cos(angle)
                        dy = sin(angle)
                        distance = 1
                    }

                    guard distance < minimumDistance else { continue }

                    let push = (minimumDistance - distance) * 0.5
                    let unitX = dx / distance
                    let unitY = dy / distance
                    left.x += unitX * push
                    left.y += unitY * push
                    right.x -= unitX * push
                    right.y -= unitY * push
                    adjusted[leftId] = left
                    adjusted[rightId] = right
                }
            }
        }

        return adjusted
    }

    private func connectedComponents(nodes: [NousNode], edges: [NodeEdge]) -> [[UUID]] {
        let visibleIds = Set(nodes.map(\.id))
        var neighbors = Dictionary(uniqueKeysWithValues: visibleIds.map { ($0, Set<UUID>()) })
        for edge in edges where visibleIds.contains(edge.sourceId) && visibleIds.contains(edge.targetId) {
            neighbors[edge.sourceId, default: []].insert(edge.targetId)
            neighbors[edge.targetId, default: []].insert(edge.sourceId)
        }

        var visited = Set<UUID>()
        var components: [[UUID]] = []

        for node in nodes where !visited.contains(node.id) {
            var stack = [node.id]
            var component: [UUID] = []
            visited.insert(node.id)

            while let id = stack.popLast() {
                component.append(id)
                for neighbor in neighbors[id, default: []] where !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    stack.append(neighbor)
                }
            }

            components.append(component)
        }

        return components
    }

    private func center(of positions: [UUID: GraphPosition]) -> GraphPosition {
        guard !positions.isEmpty else { return GraphPosition(x: 0, y: 0) }

        let total = positions.values.reduce(GraphPosition(x: 0, y: 0)) { partial, position in
            GraphPosition(x: partial.x + position.x, y: partial.y + position.y)
        }
        let count = Float(positions.count)
        return GraphPosition(x: total.x / count, y: total.y / count)
    }

    private func maxSpan(in positions: [UUID: GraphPosition]) -> Float {
        guard
            let minX = positions.values.map(\.x).min(),
            let maxX = positions.values.map(\.x).max(),
            let minY = positions.values.map(\.y).min(),
            let maxY = positions.values.map(\.y).max()
        else { return 0 }

        return max(maxX - minX, maxY - minY)
    }

    private func normalize(_ positions: [UUID: GraphPosition], targetSpan: Float) -> [UUID: GraphPosition] {
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
        let scale = targetSpan / max(width, height)
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

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
