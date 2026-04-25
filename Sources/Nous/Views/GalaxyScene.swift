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
        backgroundColor = .clear
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

            switch edge.type {
            case .manual:
                line.strokeColor = SKColor(red: 243/255, green: 131/255, blue: 53/255, alpha: isSelectedEdge ? 0.24 : 0.14)
                line.lineWidth = isSelectedEdge ? 1.1 : 0.9
            case .shared:
                line.strokeColor = SKColor(red: 243/255, green: 131/255, blue: 53/255, alpha: isSelectedEdge ? 0.16 : 0.05 + strength * 0.05)
                line.lineWidth = isSelectedEdge ? 0.95 : 0.65
            case .semantic:
                line.strokeColor = isSelectedEdge
                    ? SKColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.18 + strength * 0.06)
                    : SKColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 0.08 + strength * 0.07)
                line.lineWidth = isSelectedEdge ? 1.0 : 0.7 + strength * 0.18
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
            circle.lineWidth = isSelected || node.isFavorite ? 1.0 : 0.6
            circle.glowWidth = 0
            circle.name = node.id.uuidString
            circle.zPosition = 1

            if isSelected || node.isFavorite {
                let emphasisRing = SKShapeNode(circleOfRadius: CGFloat(radius + 5))
                emphasisRing.strokeColor = SKColor(red: 243/255, green: 131/255, blue: 53/255, alpha: isSelected ? 0.20 : 0.14)
                emphasisRing.lineWidth = 1
                emphasisRing.fillColor = .clear
                emphasisRing.zPosition = 0
                circle.addChild(emphasisRing)
            }

            // Title label below circle
            let titleLabel = SKLabelNode(text: truncated(node.title, maxLen: 24))
            titleLabel.fontName = "SF Pro Text"
            titleLabel.fontSize = isSelected ? 11 : 10
            titleLabel.fontColor = labelColor(for: node, isSelected: isSelected)
            titleLabel.verticalAlignmentMode = .top
            titleLabel.horizontalAlignmentMode = .center
            titleLabel.position = CGPoint(x: 0, y: -(CGFloat(radius) + 8))
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
        let contentWeight = min(sqrt(Double(node.content.count)) * 0.12, 2.4)
        let degreeWeight = min(Double(degree) * 0.45, 3.2)
        let favoriteWeight = node.isFavorite ? 1.0 : 0.0
        return CGFloat(4.5 + contentWeight + degreeWeight + favoriteWeight)
    }

    private func fillColor(for node: NousNode, isSelected: Bool) -> SKColor {
        if isSelected {
            return SKColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.88)
        }

        switch node.type {
        case .conversation:
            return SKColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.78)
        case .note:
            return SKColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 0.84)
        }
    }

    private func strokeColor(for node: NousNode, isSelected: Bool) -> SKColor {
        if isSelected {
            return SKColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.74)
        }

        if node.isFavorite {
            return SKColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.30)
        }

        return SKColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 0.10)
    }

    private func labelColor(for node: NousNode, isSelected: Bool) -> SKColor {
        if isSelected {
            return SKColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 0.90)
        }

        switch node.type {
        case .conversation:
            return SKColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 0.72)
        case .note:
            return SKColor(red: 51/255, green: 51/255, blue: 51/255, alpha: 0.68)
        }
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
