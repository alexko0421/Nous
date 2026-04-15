import SpriteKit
import SwiftUI

final class GalaxyScene: SKScene {

    var graphNodes: [NousNode] = []
    var graphEdges: [NodeEdge] = []
    var positions: [UUID: GraphPosition] = [:]
    var onNodeTapped: ((UUID) -> Void)?

    // Morandi color palette
    private static let projectColors: [SKColor] = [
        SKColor(red: 198/255, green: 163/255, blue: 138/255, alpha: 1), // warm sand
        SKColor(red: 163/255, green: 180/255, blue: 180/255, alpha: 1), // sage grey
        SKColor(red: 188/255, green: 157/255, blue: 169/255, alpha: 1), // dusty rose
        SKColor(red: 155/255, green: 175/255, blue: 155/255, alpha: 1), // muted green
        SKColor(red: 170/255, green: 163/255, blue: 189/255, alpha: 1), // lavender grey
        SKColor(red: 198/255, green: 178/255, blue: 155/255, alpha: 1), // warm taupe
        SKColor(red: 155/255, green: 170/255, blue: 185/255, alpha: 1), // steel blue
        SKColor(red: 189/255, green: 163/255, blue: 155/255, alpha: 1), // terracotta mute
    ]

    private var projectColorMap: [UUID: Int] = [:]
    private var cameraNode = SKCameraNode()
    private var draggedNode: SKNode?
    private var dragStartPosition: CGPoint = .zero
    private var mouseDownTime: TimeInterval = 0
    private var nodeSprites: [UUID: SKShapeNode] = [:]
    private var edgeSprites: [String: SKShapeNode] = [:]
    private var selectedNodeId: UUID?

    // Force-directed physics state
    private var velocities: [UUID: CGPoint] = [:]
    private var isPhysicsActive = true
    private var physicsIterations = 0

    // ForceAtlas2 parameters (matching Principia)
    private let gravitationalConstant: CGFloat = -40
    private let centralGravity: CGFloat = 0.005
    private let springLength: CGFloat = 120
    private let springConstant: CGFloat = 0.04
    private let damping: CGFloat = 0.82
    private let maxVelocity: CGFloat = 15
    private let minVelocity: CGFloat = 0.05
    private let stabilizationIterations = 150

    // MARK: - Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 253/255, green: 251/255, blue: 247/255, alpha: 1)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)

        view.window?.isMovableByWindowBackground = false

        addChild(cameraNode)
        camera = cameraNode

        buildProjectColorMap()
        initializePositions()
        drawEdges()
        drawNodes()

        isPhysicsActive = true
        physicsIterations = 0
    }

    override func willMove(from view: SKView) {
        view.window?.isMovableByWindowBackground = true
    }

    // MARK: - Force-Directed Layout (ForceAtlas2)

    override func update(_ currentTime: TimeInterval) {
        guard isPhysicsActive else { return }

        applyForces()
        updatePositions()
        updateEdgeLines()

        physicsIterations += 1
        if physicsIterations > stabilizationIterations {
            // Check if settled
            let maxVel = velocities.values.map { sqrt($0.x * $0.x + $0.y * $0.y) }.max() ?? 0
            if maxVel < minVelocity {
                isPhysicsActive = false
            }
        }
    }

    private func applyForces() {
        let nodeIds = Array(nodeSprites.keys)

        // Reset forces
        var forces: [UUID: CGPoint] = [:]
        for id in nodeIds { forces[id] = .zero }

        // Repulsion (between all node pairs)
        for i in 0..<nodeIds.count {
            for j in (i+1)..<nodeIds.count {
                let idA = nodeIds[i]
                let idB = nodeIds[j]
                guard let spriteA = nodeSprites[idA], let spriteB = nodeSprites[idB] else { continue }

                var dx = spriteA.position.x - spriteB.position.x
                var dy = spriteA.position.y - spriteB.position.y
                var dist = sqrt(dx * dx + dy * dy)
                if dist < 1 { dist = 1; dx = CGFloat.random(in: -1...1); dy = CGFloat.random(in: -1...1) }

                let force = gravitationalConstant / dist
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force

                forces[idA] = CGPoint(x: (forces[idA]?.x ?? 0) - fx, y: (forces[idA]?.y ?? 0) - fy)
                forces[idB] = CGPoint(x: (forces[idB]?.x ?? 0) + fx, y: (forces[idB]?.y ?? 0) + fy)
            }
        }

        // Attraction (along edges)
        for edge in graphEdges {
            guard let spriteA = nodeSprites[edge.sourceId], let spriteB = nodeSprites[edge.targetId] else { continue }

            let dx = spriteB.position.x - spriteA.position.x
            let dy = spriteB.position.y - spriteA.position.y
            let dist = sqrt(dx * dx + dy * dy)
            guard dist > 0 else { continue }

            let displacement = dist - springLength
            let force = springConstant * displacement
            let fx = (dx / dist) * force
            let fy = (dy / dist) * force

            forces[edge.sourceId] = CGPoint(x: (forces[edge.sourceId]?.x ?? 0) + fx, y: (forces[edge.sourceId]?.y ?? 0) + fy)
            forces[edge.targetId] = CGPoint(x: (forces[edge.targetId]?.x ?? 0) - fx, y: (forces[edge.targetId]?.y ?? 0) - fy)
        }

        // Central gravity
        for id in nodeIds {
            guard let sprite = nodeSprites[id] else { continue }
            let dx = -sprite.position.x
            let dy = -sprite.position.y
            forces[id] = CGPoint(x: (forces[id]?.x ?? 0) + dx * centralGravity, y: (forces[id]?.y ?? 0) + dy * centralGravity)
        }

        // Apply forces to velocities with damping
        for id in nodeIds {
            // Skip dragged node
            if let dragged = draggedNode, dragged.name == id.uuidString { continue }

            var vel = velocities[id] ?? .zero
            vel.x = (vel.x + (forces[id]?.x ?? 0)) * damping
            vel.y = (vel.y + (forces[id]?.y ?? 0)) * damping

            // Clamp velocity
            let speed = sqrt(vel.x * vel.x + vel.y * vel.y)
            if speed > maxVelocity {
                vel.x = vel.x / speed * maxVelocity
                vel.y = vel.y / speed * maxVelocity
            }

            velocities[id] = vel
        }
    }

    private func updatePositions() {
        for (id, sprite) in nodeSprites {
            guard let vel = velocities[id] else { continue }
            if let dragged = draggedNode, dragged.name == id.uuidString { continue }

            sprite.position.x += vel.x
            sprite.position.y += vel.y
            positions[id] = GraphPosition(x: Float(sprite.position.x), y: Float(sprite.position.y))
        }
    }

    private func updateEdgeLines() {
        for (key, line) in edgeSprites {
            let parts = key.split(separator: "|")
            guard parts.count == 2,
                  let srcId = UUID(uuidString: String(parts[0])),
                  let tgtId = UUID(uuidString: String(parts[1])),
                  let srcSprite = nodeSprites[srcId],
                  let tgtSprite = nodeSprites[tgtId] else { continue }

            let src = srcSprite.position
            let tgt = tgtSprite.position
            let mid = CGPoint(x: (src.x + tgt.x) / 2, y: (src.y + tgt.y) / 2)
            let dx = tgt.x - src.x
            let dy = tgt.y - src.y
            let ctrl = CGPoint(x: mid.x - dy * 0.1, y: mid.y + dx * 0.1)

            let path = CGMutablePath()
            path.move(to: src)
            path.addQuadCurve(to: tgt, control: ctrl)
            line.path = path
        }
    }

    // MARK: - Scene Building

    private func buildProjectColorMap() {
        projectColorMap.removeAll()
        var idx = 1
        for pid in Set(graphNodes.compactMap(\.projectId)) {
            projectColorMap[pid] = idx % Self.projectColors.count
            idx += 1
        }
    }

    private func initializePositions() {
        // Use existing positions or random scatter
        for node in graphNodes {
            if positions[node.id] == nil {
                let x = Float.random(in: -200...200)
                let y = Float.random(in: -200...200)
                positions[node.id] = GraphPosition(x: x, y: y)
            }
            velocities[node.id] = .zero
        }
    }

    private func drawEdges() {
        for edge in graphEdges {
            guard
                let srcPos = positions[edge.sourceId],
                let tgtPos = positions[edge.targetId]
            else { continue }

            let src = CGPoint(x: CGFloat(srcPos.x), y: CGFloat(srcPos.y))
            let tgt = CGPoint(x: CGFloat(tgtPos.x), y: CGFloat(tgtPos.y))
            let mid = CGPoint(x: (src.x + tgt.x) / 2, y: (src.y + tgt.y) / 2)
            let dx = tgt.x - src.x
            let dy = tgt.y - src.y
            let ctrl = CGPoint(x: mid.x - dy * 0.1, y: mid.y + dx * 0.1)

            let path = CGMutablePath()
            path.move(to: src)
            path.addQuadCurve(to: tgt, control: ctrl)

            let line = SKShapeNode(path: path)
            line.strokeColor = SKColor(white: 0, alpha: 0.05)
            line.lineWidth = 1.5
            line.lineCap = .round
            line.zPosition = -1
            addChild(line)

            let key = "\(edge.sourceId.uuidString)|\(edge.targetId.uuidString)"
            edgeSprites[key] = line
        }
    }

    private func drawNodes() {
        for node in graphNodes {
            guard let pos = positions[node.id] else { continue }

            let edgeCount = graphEdges.filter { $0.sourceId == node.id || $0.targetId == node.id }.count
            let radius = max(6.0, min(14.0, 6.0 + Double(edgeCount) * 1.5))

            let colorIndex = node.projectId.flatMap { projectColorMap[$0] } ?? 0
            let nodeColor = Self.projectColors[colorIndex]

            let circle = SKShapeNode(circleOfRadius: CGFloat(radius))
            circle.position = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
            circle.fillColor = nodeColor
            circle.strokeColor = nodeColor.withAlphaComponent(0.3)
            circle.lineWidth = 1
            circle.glowWidth = 2
            circle.name = node.id.uuidString
            circle.zPosition = 1

            let titleLabel = SKLabelNode(text: truncated(node.title, maxLen: 24))
            titleLabel.fontName = "SF Pro Text"
            titleLabel.fontSize = 10
            titleLabel.fontColor = SKColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 0.65)
            titleLabel.verticalAlignmentMode = .top
            titleLabel.horizontalAlignmentMode = .center
            titleLabel.position = CGPoint(x: 0, y: -(CGFloat(radius) + 3))
            titleLabel.zPosition = 2
            circle.addChild(titleLabel)

            addChild(circle)
            nodeSprites[node.id] = circle
        }
    }

    private func truncated(_ text: String, maxLen: Int) -> String {
        guard text.count > maxLen else { return text }
        return String(text.prefix(maxLen)) + "…"
    }

    // MARK: - Interactive Lighting

    private func connectedEdgeKeys(for nodeId: UUID) -> [String] {
        let idStr = nodeId.uuidString
        return edgeSprites.keys.filter { key in
            let parts = key.split(separator: "|")
            guard parts.count == 2 else { return false }
            return parts[0] == idStr || parts[1] == idStr
        }
    }

    private func connectedNodeIds(for nodeId: UUID) -> Set<UUID> {
        let idStr = nodeId.uuidString
        var connected = Set<UUID>()
        for key in edgeSprites.keys {
            let parts = key.split(separator: "|")
            guard parts.count == 2 else { continue }
            if String(parts[0]) == idStr, let uuid = UUID(uuidString: String(parts[1])) {
                connected.insert(uuid)
            } else if String(parts[1]) == idStr, let uuid = UUID(uuidString: String(parts[0])) {
                connected.insert(uuid)
            }
        }
        return connected
    }

    private func resetToQuiet() {
        selectedNodeId = nil
        for (_, line) in edgeSprites {
            line.strokeColor = SKColor(white: 0, alpha: 0.05)
            line.lineWidth = 1.5
            line.glowWidth = 0
        }
        for (id, sprite) in nodeSprites {
            sprite.alpha = 1.0
            let colorIndex = graphNodes.first(where: { $0.id == id })?.projectId.flatMap({ projectColorMap[$0] }) ?? 0
            let nodeColor = Self.projectColors[colorIndex]
            sprite.fillColor = nodeColor
            sprite.strokeColor = nodeColor.withAlphaComponent(0.3)
            sprite.glowWidth = 2
        }
    }

    private func highlightNode(_ nodeId: UUID) {
        resetToQuiet()
        selectedNodeId = nodeId
        for key in connectedEdgeKeys(for: nodeId) {
            if let line = edgeSprites[key] {
                line.strokeColor = SKColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.8)
                line.lineWidth = 2.5
                line.glowWidth = 8
            }
        }
        if let sprite = nodeSprites[nodeId] {
            sprite.glowWidth = 12
        }
    }

    private func spotlightNode(_ nodeId: UUID) {
        selectedNodeId = nodeId
        let family = connectedNodeIds(for: nodeId).union([nodeId])
        for (id, sprite) in nodeSprites {
            sprite.alpha = family.contains(id) ? 1.0 : 0.1
            if id == nodeId { sprite.glowWidth = 12 }
            else if family.contains(id) { sprite.glowWidth = 6 }
        }
        for (key, line) in edgeSprites {
            let parts = key.split(separator: "|")
            guard parts.count == 2,
                  let srcId = UUID(uuidString: String(parts[0])),
                  let tgtId = UUID(uuidString: String(parts[1])) else { continue }
            if family.contains(srcId) && family.contains(tgtId) {
                line.strokeColor = SKColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.8)
                line.lineWidth = 2.5
                line.glowWidth = 8
            } else {
                line.strokeColor = SKColor(white: 0, alpha: 0.03)
                line.lineWidth = 1
                line.glowWidth = 0
            }
        }
    }

    // MARK: - Hit Testing

    private func nodeAt(point: CGPoint) -> (SKShapeNode, UUID)? {
        for (id, sprite) in nodeSprites {
            if sprite.frame.insetBy(dx: -10, dy: -10).contains(point) {
                return (sprite, id)
            }
        }
        return nil
    }

    private func scenePoint(from event: NSEvent) -> CGPoint {
        event.location(in: self)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = scenePoint(from: event)
        mouseDownTime = event.timestamp
        if let (sprite, _) = nodeAt(point: point) {
            draggedNode = sprite
            dragStartPosition = point
            isPhysicsActive = true // Wake up physics when dragging
        } else {
            resetToQuiet()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragged = draggedNode else { return }
        let point = scenePoint(from: event)
        dragged.position = point
        if let name = dragged.name, let id = UUID(uuidString: name) {
            positions[id] = GraphPosition(x: Float(point.x), y: Float(point.y))
            velocities[id] = .zero
        }
    }

    override func mouseUp(with event: NSEvent) {
        // Zero out all velocities so nothing drifts after release
        for id in velocities.keys { velocities[id] = .zero }

        defer { draggedNode = nil }
        guard let dragged = draggedNode else { return }

        let point = scenePoint(from: event)
        let dx = point.x - dragStartPosition.x
        let dy = point.y - dragStartPosition.y
        let distance = sqrt(dx * dx + dy * dy)
        let holdDuration = event.timestamp - mouseDownTime

        guard distance < 5 else { return }
        guard let name = dragged.name, let id = UUID(uuidString: name) else { return }

        if holdDuration > 0.5 {
            spotlightNode(id)
        } else {
            if selectedNodeId == id {
                resetToQuiet()
            } else {
                highlightNode(id)
            }
            onNodeTapped?(id)
        }
    }

    // MARK: - Zoom

    override func scrollWheel(with event: NSEvent) {
        let zoomDelta = event.deltaY * 0.01
        let newScale = (cameraNode.xScale - zoomDelta).clamped(to: 0.3...3.0)
        cameraNode.setScale(newScale)
    }

    override func magnify(with event: NSEvent) {
        let newScale = (cameraNode.xScale * (1 - event.magnification)).clamped(to: 0.3...3.0)
        cameraNode.setScale(newScale)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
