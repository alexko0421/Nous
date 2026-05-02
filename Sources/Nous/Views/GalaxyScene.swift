import SpriteKit
import SwiftUI

enum GalaxySceneTapTarget: Equatable {
    case node(UUID)
    case edge(UUID)
    case canvas
}

final class GalaxyScene: SKScene {

    var graphNodes: [NousNode] = []
    var graphEdges: [NodeEdge] = []
    var highlightedEdgeIds: Set<UUID> = []
    var positions: [UUID: GraphPosition] = [:]
    var selectedNodeId: UUID?
    var selectedEdgeId: UUID?
    var onNodeTapped: ((UUID) -> Void)?
    var onEdgeTapped: ((UUID) -> Void)?
    var onCanvasTapped: (() -> Void)?
    var onNodeMoved: ((UUID, GraphPosition) -> Void)?

    private var cameraNode: SKCameraNode = SKCameraNode()
    private let layoutEngine = GraphLayoutEngine()
    private var draggedNode: SKNode?
    private var pressedEdgeId: UUID?
    private var pressedCanvas = false
    private var dragStartPosition: CGPoint = .zero
    private var edgeSprites: [UUID: SKShapeNode] = [:]
    private var nodeSprites: [UUID: SKShapeNode] = [:]
    private var nodeTitleLabels: [UUID: SKLabelNode] = [:]
    private var nodeHitRadii: [UUID: CGFloat] = [:]
    private var fittedNodeIds: [UUID] = []

    // MARK: - Lifecycle

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        anchorPoint = CGPoint(x: 0.5, y: 0.5)

        installCameraIfNeeded()

        rebuildScene()
    }

    private func installCameraIfNeeded() {
        if cameraNode.parent !== self {
            cameraNode.removeFromParent()
            addChild(cameraNode)
        }

        camera = cameraNode
    }

    // MARK: - Scene Building

    func rebuildScene() {
        rebuildScene(preservingCamera: false)
    }

    func refreshPresentationState() {
        rebuildScene(preservingCamera: true)
    }

    private func rebuildScene(preservingCamera: Bool) {
        let previousCameraPosition = cameraNode.position
        let previousCameraScale = cameraNode.xScale

        // Remove all existing children except camera
        children.forEach { node in
            if node !== cameraNode { node.removeFromParent() }
        }
        edgeSprites.removeAll()
        nodeSprites.removeAll()
        nodeTitleLabels.removeAll()
        nodeHitRadii.removeAll()

        drawEdges()
        drawNodes()

        if preservingCamera {
            cameraNode.position = previousCameraPosition
            cameraNode.setScale(previousCameraScale)
            updateTitleLabelVisibility()
        } else {
            fitCameraToGraphIfNeeded()
        }
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
            let isSelectedEdge = edge.id == selectedEdgeId
            let touchesSelectedNode = edge.sourceId == selectedNodeId || edge.targetId == selectedNodeId
            let isHighlightedEdge = highlightedEdgeIds.contains(edge.id)
            let strength = CGFloat(edge.strength).clamped(to: 0...1)
            let confidence = CGFloat(edge.confidence).clamped(to: 0...1)
            let visualStrength = max(strength, confidence)
            let baseAlpha = isHighlightedEdge ? 0.36 + visualStrength * 0.22 : 0.10 + visualStrength * 0.08

            line.strokeColor = edgeColor(for: edge, alpha: isSelectedEdge ? 0.92 : (touchesSelectedNode ? max(baseAlpha, 0.58) : baseAlpha))
            line.lineWidth = isSelectedEdge ? 2.0 : (touchesSelectedNode ? 1.45 : (isHighlightedEdge ? 1.12 + visualStrength * 0.42 : 0.72))
            line.glowWidth = 0
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
            circle.lineWidth = isSelected || node.isFavorite ? 1.05 : 0.65
            circle.glowWidth = 0
            circle.name = node.id.uuidString
            circle.zPosition = 1

            if isSelected || node.isFavorite {
                let emphasisRing = SKShapeNode(circleOfRadius: CGFloat(radius + 3))
                emphasisRing.strokeColor = galaxyAmber(alpha: isSelected ? 0.18 : 0.09)
                emphasisRing.lineWidth = 0.7
                emphasisRing.fillColor = .clear
                emphasisRing.zPosition = 0
                circle.addChild(emphasisRing)
            }

            let titleLabel = SKLabelNode(text: truncated(node.title, maxLen: 18))
            titleLabel.name = "\(node.id.uuidString).title"
            titleLabel.fontName = "PingFang SC"
            titleLabel.fontSize = isSelected ? 8.5 : 8
            titleLabel.fontColor = labelColor(for: node, isSelected: isSelected)
            titleLabel.verticalAlignmentMode = .top
            titleLabel.horizontalAlignmentMode = .center
            titleLabel.position = CGPoint(x: 0, y: -(CGFloat(radius) + 3))
            titleLabel.zPosition = 2
            titleLabel.alpha = titleLabelAlpha(for: node, isSelected: isSelected)
            circle.addChild(titleLabel)
            nodeTitleLabels[node.id] = titleLabel

            addChild(circle)
            nodeSprites[node.id] = circle
            nodeHitRadii[node.id] = max(22, radius + 16)
        }
    }

    private func fitCameraToGraphIfNeeded() {
        guard size.width > 1, size.height > 1, !graphNodes.isEmpty else { return }

        let nodeIds = graphNodes.map(\.id)
        guard fittedNodeIds != nodeIds else { return }

        fitCameraToGraph()
        fittedNodeIds = nodeIds
    }

    private func fitCameraToGraph() {
        let visiblePositions = graphNodes.compactMap { positions[$0.id] }
        guard !visiblePositions.isEmpty else {
            cameraNode.position = .zero
            cameraNode.setScale(1)
            return
        }

        let xs = visiblePositions.map { CGFloat($0.x) }
        let ys = visiblePositions.map { CGFloat($0.y) }
        guard
            let minX = xs.min(),
            let maxX = xs.max(),
            let minY = ys.min(),
            let maxY = ys.max()
        else { return }

        let contentWidth = max(maxX - minX, 1) + 220
        let contentHeight = max(maxY - minY, 1) + 190
        let xScale = contentWidth / max(size.width, 1)
        let yScale = contentHeight / max(size.height, 1)
        let scale = max(xScale, yScale).clamped(to: 0.55...2.1)

        cameraNode.position = CGPoint(x: (minX + maxX) * 0.5, y: (minY + maxY) * 0.5)
        cameraNode.setScale(scale)
        updateTitleLabelVisibility()
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
        let contentWeight = min(sqrt(Double(node.content.count)) * 0.07, 2.0)
        let degreeWeight = min(Double(degree) * 0.18, 1.2)
        let favoriteWeight = node.isFavorite ? 0.8 : 0.0
        return CGFloat(max(5.2, min(12.0, 5.8 + contentWeight + degreeWeight + favoriteWeight)))
    }

    private func shouldShowLabel(for node: NousNode, isSelected: Bool) -> Bool {
        isSelected || node.isFavorite || cameraNode.xScale <= GalaxyZoomPresentation.titleRevealScale
    }

    private func titleLabelAlpha(for node: NousNode, isSelected: Bool) -> CGFloat {
        shouldShowLabel(for: node, isSelected: isSelected) ? 1 : 0
    }

    private func updateTitleLabelVisibility() {
        for node in graphNodes {
            guard let titleLabel = nodeTitleLabels[node.id] else { continue }
            let isSelected = node.id == selectedNodeId
            titleLabel.alpha = titleLabelAlpha(for: node, isSelected: isSelected)
            titleLabel.fontColor = labelColor(for: node, isSelected: isSelected)
        }
    }

    private func fillColor(for node: NousNode, isSelected: Bool) -> SKColor {
        if isSelected {
            return galaxyAmber(alpha: 0.98)
        }

        if node.isFavorite {
            return champagneNode(alpha: 0.96)
        }

        switch nodePaletteIndex(for: node) {
        case 0:
            return ivoryNode(alpha: 0.95)
        case 1:
            return warmOrangeNode(alpha: 0.94)
        case 2:
            return sageNode(alpha: 0.94)
        case 3:
            return blueMistNode(alpha: 0.93)
        default:
            return roseTaupeNode(alpha: 0.94)
        }
    }

    private func strokeColor(for node: NousNode, isSelected: Bool) -> SKColor {
        if isSelected {
            return galaxyAmber(alpha: 0.58)
        }

        if node.isFavorite {
            return galaxyAmber(alpha: 0.44)
        }

        return ivoryNode(alpha: 0.30)
    }

    private func edgeColor(for edge: NodeEdge, alpha: CGFloat) -> SKColor {
        switch edge.type {
        case .manual:
            return galaxyAmber(alpha: alpha)
        case .shared:
            return blueMistLine(alpha: alpha)
        case .semantic:
            switch edge.relationKind {
            case .tension, .contradicts:
                return galaxyAmber(alpha: alpha)
            case .samePattern:
                return plumLine(alpha: alpha)
            case .supports, .causeEffect:
                return sageLine(alpha: alpha)
            case .topicSimilarity:
                return quietLine(alpha: alpha)
            }
        }
    }

    private func nodePaletteIndex(for node: NousNode) -> Int {
        node.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 5
    }

    private func labelColor(for node: NousNode, isSelected: Bool) -> SKColor {
        if isSelected {
            return ivoryNode(alpha: 0.96)
        }

        return ivoryNode(alpha: node.type == .conversation ? 0.82 : 0.66)
    }

    private func galaxyAmber(alpha: CGFloat) -> SKColor {
        SKColor(red: 226/255, green: 184/255, blue: 132/255, alpha: alpha)
    }

    private func ivoryNode(alpha: CGFloat) -> SKColor {
        SKColor(red: 242/255, green: 229/255, blue: 205/255, alpha: alpha)
    }

    private func taupeNode(alpha: CGFloat) -> SKColor {
        SKColor(red: 184/255, green: 166/255, blue: 139/255, alpha: alpha)
    }

    private func champagneNode(alpha: CGFloat) -> SKColor {
        SKColor(red: 236/255, green: 202/255, blue: 144/255, alpha: alpha)
    }

    private func warmOrangeNode(alpha: CGFloat) -> SKColor {
        SKColor(red: 227/255, green: 166/255, blue: 95/255, alpha: alpha)
    }

    private func sageNode(alpha: CGFloat) -> SKColor {
        SKColor(red: 166/255, green: 179/255, blue: 142/255, alpha: alpha)
    }

    private func blueMistNode(alpha: CGFloat) -> SKColor {
        SKColor(red: 150/255, green: 169/255, blue: 184/255, alpha: alpha)
    }

    private func roseTaupeNode(alpha: CGFloat) -> SKColor {
        SKColor(red: 190/255, green: 145/255, blue: 133/255, alpha: alpha)
    }

    private func quietLine(alpha: CGFloat) -> SKColor {
        SKColor(red: 216/255, green: 204/255, blue: 184/255, alpha: alpha)
    }

    private func blueMistLine(alpha: CGFloat) -> SKColor {
        SKColor(red: 142/255, green: 169/255, blue: 185/255, alpha: alpha)
    }

    private func sageLine(alpha: CGFloat) -> SKColor {
        SKColor(red: 173/255, green: 190/255, blue: 147/255, alpha: alpha)
    }

    private func plumLine(alpha: CGFloat) -> SKColor {
        SKColor(red: 188/255, green: 157/255, blue: 204/255, alpha: alpha)
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
            let storedHitRadius = nodeHitRadii[id] ?? max(sprite.frame.width, sprite.frame.height) * 0.5
            let hitRadius = max(storedHitRadius, 24 * cameraNode.xScale)

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

    func edgeId(at point: CGPoint) -> UUID? {
        var closest: (id: UUID, distance: CGFloat)?

        for edge in graphEdges {
            guard
                let source = positions[edge.sourceId],
                let target = positions[edge.targetId]
            else { continue }

            let start = CGPoint(x: CGFloat(source.x), y: CGFloat(source.y))
            let end = CGPoint(x: CGFloat(target.x), y: CGFloat(target.y))
            let distance = distanceFrom(point: point, toSegmentFrom: start, to: end)
            guard distance <= 10 else { continue }

            if let current = closest {
                if distance < current.distance {
                    closest = (edge.id, distance)
                }
            } else {
                closest = (edge.id, distance)
            }
        }

        return closest?.id
    }

    func tapTarget(at point: CGPoint) -> GalaxySceneTapTarget {
        if let (_, id) = nodeAt(point: point) {
            return .node(id)
        }

        if let edgeId = edgeId(at: point) {
            return .edge(edgeId)
        }

        return .canvas
    }

    private func distanceFrom(point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else {
            let px = point.x - start.x
            let py = point.y - start.y
            return sqrt(px * px + py * py)
        }

        let projection = (((point.x - start.x) * dx) + ((point.y - start.y) * dy)) / lengthSquared
        let t = projection.clamped(to: 0...1)
        let nearest = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        let px = point.x - nearest.x
        let py = point.y - nearest.y

        return sqrt(px * px + py * py)
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
        dragStartPosition = point

        switch tapTarget(at: point) {
        case .node:
            guard let (sprite, _) = nodeAt(point: point) else { return }
            draggedNode = sprite
        case .edge(let edgeId):
            pressedEdgeId = edgeId
        case .canvas:
            pressedCanvas = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragged = draggedNode else { return }
        let point = scenePoint(from: event)

        if let name = dragged.name, let id = UUID(uuidString: name) {
            let previousPositions = positions
            let previousPosition = positions[id] ?? GraphPosition(
                x: Float(dragged.position.x),
                y: Float(dragged.position.y)
            )
            let position = GraphPosition(x: Float(point.x), y: Float(point.y))
            positions = layoutEngine.relaxPositionsAfterDrag(
                draggedNodeId: id,
                from: previousPosition,
                to: position,
                positions: positions,
                edges: graphEdges
            )
            syncPositions()
            publishMovedPositions(previousPositions: previousPositions)
        } else {
            dragged.position = point
            updateEdgePaths()
        }
    }

    private func publishMovedPositions(previousPositions: [UUID: GraphPosition]) {
        for (id, position) in positions {
            guard let previous = previousPositions[id] else {
                onNodeMoved?(id, position)
                continue
            }

            let dx = abs(position.x - previous.x)
            let dy = abs(position.y - previous.y)
            guard dx > 0.001 || dy > 0.001 else { continue }
            onNodeMoved?(id, position)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            draggedNode = nil
            pressedEdgeId = nil
            pressedCanvas = false
        }

        let point = scenePoint(from: event)
        let dx = point.x - dragStartPosition.x
        let dy = point.y - dragStartPosition.y
        let distance = sqrt(dx * dx + dy * dy)

        if let edgeId = pressedEdgeId, distance < 5 {
            onEdgeTapped?(edgeId)
            return
        }

        if pressedCanvas, distance < 5 {
            onCanvasTapped?()
            return
        }

        guard let dragged = draggedNode else { return }

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
        let newScale = (cameraNode.xScale - zoomDelta).clamped(
            to: GalaxyZoomPresentation.minimumScale...GalaxyZoomPresentation.maximumScale
        )
        cameraNode.setScale(newScale)
        updateTitleLabelVisibility()
    }

    // MARK: - Zoom (trackpad pinch)

    override func magnify(with event: NSEvent) {
        let newScale = (cameraNode.xScale * (1 - event.magnification)).clamped(
            to: GalaxyZoomPresentation.minimumScale...GalaxyZoomPresentation.maximumScale
        )
        cameraNode.setScale(newScale)
        updateTitleLabelVisibility()
    }

    var cameraScaleForTesting: CGFloat {
        cameraNode.xScale
    }

    func setCameraScaleForTesting(_ scale: CGFloat) {
        cameraNode.setScale(scale)
        updateTitleLabelVisibility()
    }

    func titleLabelForTesting(nodeId: UUID) -> SKLabelNode? {
        nodeTitleLabels[nodeId]
    }

    func refreshPresentationForTesting(selectedNodeId: UUID?) {
        self.selectedNodeId = selectedNodeId
        refreshPresentationState()
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
