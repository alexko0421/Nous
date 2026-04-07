import SpriteKit
import SwiftUI

final class GalaxyScene: SKScene {

    var graphNodes: [NousNode] = []
    var graphEdges: [NodeEdge] = []
    var positions: [UUID: GraphPosition] = [:]
    var onNodeTapped: ((UUID) -> Void)?

    private var cameraNode: SKCameraNode = SKCameraNode()
    private var draggedNode: SKNode?
    private var dragStartPosition: CGPoint = .zero
    private var nodeSprites: [UUID: SKShapeNode] = [:]

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
        nodeSprites.removeAll()

        drawEdges()
        drawNodes()
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
            let alpha = CGFloat(edge.strength) * 0.4
            line.strokeColor = SKColor(red: 243/255, green: 131/255, blue: 53/255, alpha: alpha)
            line.lineWidth = CGFloat(1 + edge.strength)
            line.zPosition = -1
            addChild(line)
        }
    }

    private func drawNodes() {
        for node in graphNodes {
            guard let pos = positions[node.id] else { continue }

            let contentLen = node.content.count
            let radius = max(12.0, min(30.0, 12.0 + sqrt(Double(contentLen)) * 0.5))

            let circle = SKShapeNode(circleOfRadius: CGFloat(radius))
            circle.position = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
            circle.fillColor = SKColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.7)
            circle.strokeColor = SKColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 1.0)
            circle.lineWidth = 1.5
            circle.glowWidth = 4
            circle.name = node.id.uuidString
            circle.zPosition = 1

            // Emoji label (type indicator)
            let emoji = node.type == .conversation ? "💬" : "📝"
            let emojiLabel = SKLabelNode(text: emoji)
            emojiLabel.fontSize = CGFloat(radius * 0.85)
            emojiLabel.verticalAlignmentMode = .center
            emojiLabel.horizontalAlignmentMode = .center
            emojiLabel.zPosition = 2
            circle.addChild(emojiLabel)

            // Title label below circle
            let titleLabel = SKLabelNode(text: truncated(node.title, maxLen: 20))
            titleLabel.fontName = "SF Pro Text"
            titleLabel.fontSize = 9
            titleLabel.fontColor = SKColor(white: 0.9, alpha: 0.85)
            titleLabel.verticalAlignmentMode = .top
            titleLabel.horizontalAlignmentMode = .center
            titleLabel.position = CGPoint(x: 0, y: -(CGFloat(radius) + 4))
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

    // MARK: - Node Hit Testing

    private func nodeAt(point: CGPoint) -> (SKShapeNode, UUID)? {
        for (id, sprite) in nodeSprites {
            let localPoint = sprite.convert(point, from: self)
            if sprite.contains(localPoint) || sprite.frame.contains(point) {
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
            positions[id] = GraphPosition(x: Float(point.x), y: Float(point.y))
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
