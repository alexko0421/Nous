import SpriteKit
import SwiftUI

final class GalaxyScene: SKScene {

    var graphNodes: [NousNode] = []
    var graphEdges: [NodeEdge] = []
    var positions: [UUID: GraphPosition] = [:]
    var selectedNodeId: UUID?
    var onNodeTapped: ((UUID) -> Void)?
    var onNodeMoved: ((UUID, GraphPosition) -> Void)?

    private var cameraNode: SKCameraNode = SKCameraNode()
    private var draggedNode: SKNode?
    private var dragStartPosition: CGPoint = .zero
    private var edgeSprites: [UUID: SKShapeNode] = [:]
    private var nodeSprites: [UUID: SKShapeNode] = [:]
    private var nodeHitRadii: [UUID: CGFloat] = [:]

    // MARK: - Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 26/255, green: 26/255, blue: 46/255, alpha: 1)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)

        addChild(cameraNode)
        camera = cameraNode

        rebuildScene()
    }

    // MARK: - Scene Building

    func rebuildScene() {
        // Remove all existing children except camera
        children.forEach { node in
            if node !== cameraNode { node.removeFromParent() }
        }
        edgeSprites.removeAll()
        nodeSprites.removeAll()
        nodeHitRadii.removeAll()

        drawEdges()
        drawNodes()
    }

    func syncPositions() {
        for (id, sprite) in nodeSprites {
            guard let position = positions[id] else { continue }
            sprite.position = CGPoint(x: CGFloat(position.x), y: CGFloat(position.y))
        }

        updateEdgePaths()
    }

    private func drawEdges() {
        for edge in graphEdges {
            guard
                let srcPos = positions[edge.sourceId],
                let tgtPos = positions[edge.targetId]
            else { continue }

            let path = CGMutablePath()
            path.move(to: CGPoint(x: CGFloat(srcPos.x), y: CGFloat(srcPos.y)))
            path.addLine(to: CGPoint(x: CGFloat(tgtPos.x), y: CGFloat(tgtPos.y)))

            let line = SKShapeNode(path: path)
            let isSelectedEdge = edge.sourceId == selectedNodeId || edge.targetId == selectedNodeId
            let strength = CGFloat(edge.strength).clamped(to: 0...1)
            let confidence = CGFloat(edge.confidence).clamped(to: 0...1)
            let visualStrength = max(strength, confidence)

            switch edge.type {
            case .manual:
                line.strokeColor = galaxyOrange(alpha: isSelectedEdge ? 0.42 : 0.26)
                line.lineWidth = isSelectedEdge ? 1.45 : 1.2
            case .shared:
                line.strokeColor = galaxyOrange(alpha: isSelectedEdge ? 0.28 : 0.08 + visualStrength * 0.12)
                line.lineWidth = isSelectedEdge ? 1.2 : 0.75 + visualStrength * 0.25
            case .semantic:
                line.strokeColor = galaxyOrange(alpha: isSelectedEdge ? 0.34 : 0.10 + visualStrength * 0.24)
                line.lineWidth = isSelectedEdge ? 1.35 : 0.85 + visualStrength * 0.55
            }
            line.zPosition = -1
            edgeSprites[edge.id] = line
            addChild(line)
        }
    }

    private func drawNodes() {
        let degreeByNodeId = connectionCounts()

        for node in graphNodes {
            guard let pos = positions[node.id] else { continue }

            let radius = nodeRadius(for: node, degree: degreeByNodeId[node.id, default: 0])
            let isSelected = node.id == selectedNodeId
            let circleColor = fillColor(for: node, isSelected: isSelected)

            let circle = SKShapeNode(circleOfRadius: CGFloat(radius))
            circle.position = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
            circle.fillColor = circleColor
            circle.strokeColor = strokeColor(for: node, isSelected: isSelected)
            circle.lineWidth = isSelected || node.isFavorite ? 2.0 : 1.4
            circle.glowWidth = isSelected ? 8 : 4
            circle.name = node.id.uuidString
            circle.zPosition = 1

            if isSelected || node.isFavorite {
                let emphasisRing = SKShapeNode(circleOfRadius: CGFloat(radius + 5))
                emphasisRing.strokeColor = galaxyOrange(alpha: isSelected ? 0.32 : 0.18)
                emphasisRing.lineWidth = 1
                emphasisRing.fillColor = .clear
                emphasisRing.zPosition = 0
                circle.addChild(emphasisRing)
            }

            let emojiLabel = SKLabelNode(text: TopicEmojiResolver.emoji(for: node))
            emojiLabel.fontSize = CGFloat(radius * 0.85)
            emojiLabel.verticalAlignmentMode = .center
            emojiLabel.horizontalAlignmentMode = .center
            emojiLabel.zPosition = 2
            circle.addChild(emojiLabel)

            // Title label below circle
            let titleLabel = SKLabelNode(text: truncated(node.title, maxLen: 20))
            titleLabel.fontName = "SF Pro Text"
            titleLabel.fontSize = isSelected ? 10 : 9
            titleLabel.fontColor = labelColor(for: node, isSelected: isSelected)
            titleLabel.verticalAlignmentMode = .top
            titleLabel.horizontalAlignmentMode = .center
            titleLabel.position = CGPoint(x: 0, y: -(CGFloat(radius) + 4))
            titleLabel.zPosition = 2
            circle.addChild(titleLabel)

            addChild(circle)
            nodeSprites[node.id] = circle
            nodeHitRadii[node.id] = max(18, radius + 10)
        }
    }

    private func connectionCounts() -> [UUID: Int] {
        var counts: [UUID: Int] = [:]

        for edge in graphEdges {
            counts[edge.sourceId, default: 0] += 1
            counts[edge.targetId, default: 0] += 1
        }

        return counts
    }

    private func nodeRadius(for node: NousNode, degree: Int) -> CGFloat {
        let contentWeight = sqrt(Double(node.content.count)) * 0.38
        let degreeWeight = min(Double(degree) * 0.7, 4.0)
        let favoriteWeight = node.isFavorite ? 2.0 : 0.0
        return CGFloat(max(12.0, min(30.0, 12.0 + contentWeight + degreeWeight + favoriteWeight)))
    }

    private func fillColor(for node: NousNode, isSelected: Bool) -> SKColor {
        if isSelected {
            return galaxyOrange(alpha: 0.90)
        }

        return galaxyOrange(alpha: node.type == .conversation ? 0.72 : 0.62)
    }

    private func strokeColor(for node: NousNode, isSelected: Bool) -> SKColor {
        if isSelected {
            return galaxyOrange(alpha: 1.0)
        }

        if node.isFavorite {
            return galaxyOrange(alpha: 0.80)
        }

        return galaxyOrange(alpha: 0.58)
    }

    private func labelColor(for node: NousNode, isSelected: Bool) -> SKColor {
        if isSelected {
            return SKColor(white: 1, alpha: 0.94)
        }

        return SKColor(white: 0.9, alpha: node.type == .conversation ? 0.86 : 0.72)
    }

    // Morandi dusty rose — replaces the original colaOrange tint for the entire
    // Galaxy scene. Nodes / edges / emphasis rings all read through this single
    // function, so changing the RGB here pulls the whole canvas into the
    // Morandi palette in one place.
    private func galaxyOrange(alpha: CGFloat) -> SKColor {
        SKColor(red: 196/255, green: 160/255, blue: 154/255, alpha: alpha)   // #C4A09A
    }

    private func truncated(_ text: String, maxLen: Int) -> String {
        guard text.count > maxLen else { return text }
        return String(text.prefix(maxLen)) + "…"
    }

    // MARK: - Node Hit Testing

    private func nodeAt(point: CGPoint) -> (SKShapeNode, UUID)? {
        var closestMatch: (sprite: SKShapeNode, id: UUID, distance: CGFloat)?

        for (id, sprite) in nodeSprites {
            let dx = point.x - sprite.position.x
            let dy = point.y - sprite.position.y
            let distance = sqrt(dx * dx + dy * dy)
            let hitRadius = nodeHitRadii[id] ?? max(sprite.frame.width, sprite.frame.height) * 0.5

            let localPoint = sprite.convert(point, from: self)
            if distance <= hitRadius || sprite.contains(localPoint) || sprite.frame.insetBy(dx: -4, dy: -4).contains(point) {
                if let current = closestMatch {
                    if distance < current.distance {
                        closestMatch = (sprite, id, distance)
                    }
                } else {
                    closestMatch = (sprite, id, distance)
                }
            }
        }

        if let closestMatch {
            return (closestMatch.sprite, closestMatch.id)
        }

        return nil
    }

    private func scenePoint(from event: NSEvent) -> CGPoint {
        event.location(in: self)
    }

    private func updateEdgePaths() {
        for edge in graphEdges {
            guard
                let line = edgeSprites[edge.id],
                let srcPos = positions[edge.sourceId],
                let tgtPos = positions[edge.targetId]
            else { continue }

            let path = CGMutablePath()
            path.move(to: CGPoint(x: CGFloat(srcPos.x), y: CGFloat(srcPos.y)))
            path.addLine(to: CGPoint(x: CGFloat(tgtPos.x), y: CGFloat(tgtPos.y)))
            line.path = path
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = scenePoint(from: event)
        if let (sprite, _) = nodeAt(point: point) {
            draggedNode = sprite
            dragStartPosition = point
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragged = draggedNode else { return }
        let point = scenePoint(from: event)
        dragged.position = point

        // Update positions dict
        if let name = dragged.name, let id = UUID(uuidString: name) {
            let position = GraphPosition(x: Float(point.x), y: Float(point.y))
            positions[id] = position
            onNodeMoved?(id, position)
            updateEdgePaths()
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { draggedNode = nil }
        guard let dragged = draggedNode else { return }

        let point = scenePoint(from: event)
        let dx = point.x - dragStartPosition.x
        let dy = point.y - dragStartPosition.y
        let distance = sqrt(dx * dx + dy * dy)

        // Treat as tap if barely moved
        if distance < 5 {
            if let name = dragged.name, let id = UUID(uuidString: name) {
                onNodeTapped?(id)
            }
        }
    }

    // MARK: - Zoom (scroll wheel)

    override func scrollWheel(with event: NSEvent) {
        let zoomDelta = event.deltaY * 0.01
        let newScale = (cameraNode.xScale - zoomDelta).clamped(to: 0.3...3.0)
        cameraNode.setScale(newScale)
    }

    // MARK: - Zoom (trackpad pinch)

    override func magnify(with event: NSEvent) {
        let newScale = (cameraNode.xScale * (1 - event.magnification)).clamped(to: 0.3...3.0)
        cameraNode.setScale(newScale)
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
