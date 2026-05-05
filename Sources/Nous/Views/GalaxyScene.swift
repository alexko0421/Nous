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
    private var draggedNode: SKNode?
    private var draggedNodeId: UUID?
    private var draggedNodeTargetPosition: CGPoint?
    private var pressedEdgeId: UUID?
    private var pressedCanvas = false
    private var dragStartPosition: CGPoint = .zero
    private var dragStartViewPosition: CGPoint = .zero
    private var draggedNodeOffset: CGPoint = .zero
    private var cameraDragStartPosition: CGPoint = .zero
    private var dragPhysicsVelocities: [UUID: CGVector] = [:]
    private var dragPhysicsRestLengths: [UUID: CGFloat] = [:]
    private var dragPhysicsComponentIds: Set<UUID> = []
    private var dragPhysicsEdges: [NodeEdge] = []
    private var lastDragPhysicsUpdateTime: TimeInterval?
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

    override func update(_ currentTime: TimeInterval) {
        guard draggedNodeId != nil else {
            lastDragPhysicsUpdateTime = nil
            return
        }

        let rawDeltaTime = lastDragPhysicsUpdateTime.map { currentTime - $0 } ?? (1.0 / 60.0)
        lastDragPhysicsUpdateTime = currentTime

        let previousPositions = positions
        if applyDragPhysics(deltaTime: CGFloat(rawDeltaTime).clamped(to: CGFloat(1.0 / 120.0)...CGFloat(1.0 / 30.0))) {
            syncPositions()
            publishMovedPositions(previousPositions: previousPositions)
        }
    }

    private func drawEdges() {
        for edge in graphEdges {
            guard
                let srcPos = positions[edge.sourceId],
                let tgtPos = positions[edge.targetId]
            else { continue }

            let lineKind = GalaxyRelationLineKind.kind(for: edge)
            let start = CGPoint(x: CGFloat(srcPos.x), y: CGFloat(srcPos.y))
            let end = CGPoint(x: CGFloat(tgtPos.x), y: CGFloat(tgtPos.y))
            let path = edgePath(from: start, to: end, kind: lineKind)

            let line = SKShapeNode(path: path)
            let isSelectedEdge = edge.id == selectedEdgeId
            let touchesSelectedNode = edge.sourceId == selectedNodeId || edge.targetId == selectedNodeId
            let isHighlightedEdge = highlightedEdgeIds.contains(edge.id)
            let strength = CGFloat(edge.strength).clamped(to: 0...1)
            let confidence = CGFloat(edge.confidence).clamped(to: 0...1)
            let visualStrength = max(strength, confidence)
            let baseAlpha = lineKind == .candidate
                ? 0.024 + visualStrength * 0.034
                : (isHighlightedEdge ? 0.36 + visualStrength * 0.22 : 0.10 + visualStrength * 0.08)

            line.strokeColor = edgeColor(for: edge, alpha: isSelectedEdge ? 0.92 : (touchesSelectedNode ? max(baseAlpha, 0.58) : baseAlpha))
            line.lineWidth = lineWidth(
                for: lineKind,
                visualStrength: visualStrength,
                isSelectedEdge: isSelectedEdge,
                touchesSelectedNode: touchesSelectedNode,
                isHighlightedEdge: isHighlightedEdge
            )
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
                emphasisRing.strokeColor = isSelected ? galaxyAmber(alpha: 0.18) : neutralStroke(alpha: 0.16)
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
        let alpha: CGFloat = isSelected || node.isFavorite ? 0.98 : 0.94

        switch node.type {
        case .conversation:
            return neutralConversationNode(alpha: alpha)
        case .note:
            return neutralNoteNode(alpha: alpha)
        case .source:
            return galaxyAmber(alpha: alpha * 0.92)
        }
    }

    private func strokeColor(for node: NousNode, isSelected: Bool) -> SKColor {
        if isSelected {
            return galaxyAmber(alpha: 0.58)
        }

        if node.isFavorite {
            return neutralStroke(alpha: 0.52)
        }

        return neutralStroke(alpha: 0.34)
    }

    private func edgeColor(for edge: NodeEdge, alpha: CGFloat) -> SKColor {
        switch GalaxyRelationLineKind.kind(for: edge) {
        case .samePattern, .manual:
            return galaxyAmber(alpha: alpha)
        case .tension:
            return roseLine(alpha: alpha)
        case .support:
            return sageLine(alpha: alpha)
        case .sameProject:
            return blueMistLine(alpha: alpha)
        case .candidate:
            return quietLine(alpha: alpha)
        case nil:
            return quietLine(alpha: alpha)
        }
    }

    private func edgePath(
        from start: CGPoint,
        to end: CGPoint,
        kind: GalaxyRelationLineKind?
    ) -> CGPath {
        guard kind == .candidate else {
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: end)
            return path
        }

        return dashedPath(from: start, to: end, dashLength: 6, gapLength: 7)
    }

    private func dashedPath(
        from start: CGPoint,
        to end: CGPoint,
        dashLength: CGFloat,
        gapLength: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = sqrt(dx * dx + dy * dy)
        guard distance > 0 else { return path }

        let ux = dx / distance
        let uy = dy / distance
        var travelled: CGFloat = 0

        while travelled < distance {
            let dashEnd = min(travelled + dashLength, distance)
            let segmentStart = CGPoint(
                x: start.x + ux * travelled,
                y: start.y + uy * travelled
            )
            let segmentEnd = CGPoint(
                x: start.x + ux * dashEnd,
                y: start.y + uy * dashEnd
            )

            path.move(to: segmentStart)
            path.addLine(to: segmentEnd)
            travelled += dashLength + gapLength
        }

        return path
    }

    private func lineWidth(
        for kind: GalaxyRelationLineKind?,
        visualStrength: CGFloat,
        isSelectedEdge: Bool,
        touchesSelectedNode: Bool,
        isHighlightedEdge: Bool
    ) -> CGFloat {
        if kind == .candidate {
            return isSelectedEdge ? 1.35 : (touchesSelectedNode ? 1.0 : 0.38)
        }

        return isSelectedEdge ? 2.0 : (touchesSelectedNode ? 1.45 : (isHighlightedEdge ? 1.12 + visualStrength * 0.42 : 0.72))
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

    private func neutralConversationNode(alpha: CGFloat) -> SKColor {
        SKColor(red: 224/255, green: 224/255, blue: 221/255, alpha: alpha)
    }

    private func neutralNoteNode(alpha: CGFloat) -> SKColor {
        SKColor(red: 185/255, green: 186/255, blue: 185/255, alpha: alpha)
    }

    private func neutralStroke(alpha: CGFloat) -> SKColor {
        SKColor(red: 236/255, green: 232/255, blue: 224/255, alpha: alpha)
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

    private func roseLine(alpha: CGFloat) -> SKColor {
        SKColor(red: 205/255, green: 137/255, blue: 156/255, alpha: alpha)
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

    private func viewPoint(from event: NSEvent) -> CGPoint {
        guard let view else { return scenePoint(from: event) }
        let point = view.convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: point.y)
    }

    private func updateEdgePaths() {
        for edge in graphEdges {
            guard
                let line = edgeSprites[edge.id],
                let srcPos = positions[edge.sourceId],
                let tgtPos = positions[edge.targetId]
            else { continue }

            let start = CGPoint(x: CGFloat(srcPos.x), y: CGFloat(srcPos.y))
            let end = CGPoint(x: CGFloat(tgtPos.x), y: CGFloat(tgtPos.y))
            line.path = edgePath(
                from: start,
                to: end,
                kind: GalaxyRelationLineKind.kind(for: edge)
            )
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        beginPointerInteraction(
            at: scenePoint(from: event),
            viewPoint: viewPoint(from: event)
        )
    }

    private func beginPointerInteraction(at point: CGPoint, viewPoint: CGPoint) {
        dragStartPosition = point
        dragStartViewPosition = viewPoint
        draggedNodeOffset = .zero
        cameraDragStartPosition = cameraNode.position

        switch tapTarget(at: point) {
        case .node:
            guard let (sprite, _) = nodeAt(point: point) else { return }
            draggedNode = sprite
            draggedNodeOffset = CGPoint(
                x: sprite.position.x - point.x,
                y: sprite.position.y - point.y
            )
        case .edge(let edgeId):
            pressedEdgeId = edgeId
        case .canvas:
            pressedCanvas = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        movePointerInteraction(
            to: scenePoint(from: event),
            viewPoint: viewPoint(from: event)
        )
    }

    private func movePointerInteraction(to point: CGPoint, viewPoint: CGPoint) {
        if pressedCanvas {
            let dx = viewPoint.x - dragStartViewPosition.x
            let dy = viewPoint.y - dragStartViewPosition.y
            cameraNode.position = CGPoint(
                x: cameraDragStartPosition.x - dx * cameraNode.xScale,
                y: cameraDragStartPosition.y - dy * cameraNode.yScale
            )
            updateTitleLabelVisibility()
            return
        }

        guard let dragged = draggedNode else { return }
        let centerPoint = CGPoint(
            x: point.x + draggedNodeOffset.x,
            y: point.y + draggedNodeOffset.y
        )

        if let name = dragged.name, let id = UUID(uuidString: name) {
            let previousPositions = positions
            if draggedNodeId != id {
                prepareDragPhysics(for: id)
            }
            draggedNodeTargetPosition = centerPoint
            positions[id] = GraphPosition(x: Float(centerPoint.x), y: Float(centerPoint.y))
            dragPhysicsVelocities[id] = .zero
            _ = applyDragPhysics(deltaTime: CGFloat(1.0 / 60.0))
            syncPositions()
            publishMovedPositions(previousPositions: previousPositions)
        } else {
            dragged.position = centerPoint
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
        endPointerInteraction(
            at: scenePoint(from: event),
            viewPoint: viewPoint(from: event)
        )
    }

    private func endPointerInteraction(at point: CGPoint, viewPoint: CGPoint) {
        defer {
            draggedNode = nil
            draggedNodeId = nil
            draggedNodeTargetPosition = nil
            pressedEdgeId = nil
            pressedCanvas = false
            draggedNodeOffset = .zero
            dragPhysicsVelocities.removeAll()
            dragPhysicsRestLengths.removeAll()
            dragPhysicsComponentIds.removeAll()
            dragPhysicsEdges.removeAll()
            lastDragPhysicsUpdateTime = nil
        }

        let dx = viewPoint.x - dragStartViewPosition.x
        let dy = viewPoint.y - dragStartViewPosition.y
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

    private func prepareDragPhysics(for nodeId: UUID) {
        draggedNodeId = nodeId
        dragPhysicsComponentIds = connectedComponentIds(startingAt: nodeId)
        dragPhysicsEdges = graphEdges.filter { edge in
            dragPhysicsComponentIds.contains(edge.sourceId) && dragPhysicsComponentIds.contains(edge.targetId)
        }
        dragPhysicsRestLengths = Dictionary(uniqueKeysWithValues: dragPhysicsEdges.compactMap { edge in
            guard
                let source = positions[edge.sourceId],
                let target = positions[edge.targetId]
            else { return nil }

            let dx = CGFloat(target.x - source.x)
            let dy = CGFloat(target.y - source.y)
            let distance = sqrt(dx * dx + dy * dy).clamped(to: 64...260)
            return (edge.id, distance)
        })

        for id in dragPhysicsComponentIds {
            dragPhysicsVelocities[id] = .zero
        }
        lastDragPhysicsUpdateTime = nil
    }

    private func applyDragPhysics(deltaTime: CGFloat) -> Bool {
        guard
            let draggedNodeId,
            let targetPosition = draggedNodeTargetPosition,
            positions[draggedNodeId] != nil
        else { return false }

        positions[draggedNodeId] = GraphPosition(
            x: Float(targetPosition.x),
            y: Float(targetPosition.y)
        )

        guard !dragPhysicsEdges.isEmpty else { return true }

        let frameScale = (deltaTime * 60).clamped(to: 0.25...2.0)
        let substepScale = frameScale / 2
        applyDragPhysicsSubstep(frameScale: substepScale)
        applyDragPhysicsSubstep(frameScale: substepScale)
        positions[draggedNodeId] = GraphPosition(
            x: Float(targetPosition.x),
            y: Float(targetPosition.y)
        )
        dragPhysicsVelocities[draggedNodeId] = .zero
        return true
    }

    private func applyDragPhysicsSubstep(frameScale: CGFloat) {
        guard let draggedNodeId else { return }

        var forces: [UUID: CGVector] = [:]
        for edge in dragPhysicsEdges {
            guard
                let source = positions[edge.sourceId],
                let target = positions[edge.targetId]
            else { continue }

            let dx = CGFloat(target.x - source.x)
            let dy = CGFloat(target.y - source.y)
            let distance = max(sqrt(dx * dx + dy * dy), 1)
            let unitX = dx / distance
            let unitY = dy / distance
            let restLength = dragPhysicsRestLengths[edge.id] ?? distance
            let strength = CGFloat(edge.strength).clamped(to: 0.25...1)
            let force = (distance - restLength) * 0.18 * strength
            let forceX = unitX * force
            let forceY = unitY * force

            let sourcePinned = edge.sourceId == draggedNodeId
            let targetPinned = edge.targetId == draggedNodeId
            let pinnedMultiplier: CGFloat = 1.22

            if !sourcePinned {
                let multiplier = targetPinned ? pinnedMultiplier : 1
                forces[edge.sourceId, default: .zero].dx += forceX * multiplier
                forces[edge.sourceId, default: .zero].dy += forceY * multiplier
            }
            if !targetPinned {
                let multiplier = sourcePinned ? pinnedMultiplier : 1
                forces[edge.targetId, default: .zero].dx -= forceX * multiplier
                forces[edge.targetId, default: .zero].dy -= forceY * multiplier
            }
        }

        let damping = pow(0.82, frameScale)
        for id in dragPhysicsComponentIds where id != draggedNodeId {
            guard var position = positions[id] else { continue }

            let force = forces[id, default: .zero]
            var velocity = dragPhysicsVelocities[id, default: .zero]
            velocity.dx = (velocity.dx + force.dx * frameScale).clamped(to: -34...34) * damping
            velocity.dy = (velocity.dy + force.dy * frameScale).clamped(to: -34...34) * damping

            position.x += Float(velocity.dx * frameScale)
            position.y += Float(velocity.dy * frameScale)
            positions[id] = position
            dragPhysicsVelocities[id] = velocity
        }
    }

    private func connectedComponentIds(startingAt startId: UUID) -> Set<UUID> {
        var adjacency: [UUID: Set<UUID>] = [:]
        for edge in graphEdges {
            adjacency[edge.sourceId, default: []].insert(edge.targetId)
            adjacency[edge.targetId, default: []].insert(edge.sourceId)
        }

        var visited: Set<UUID> = [startId]
        var queue = Array(adjacency[startId, default: []])
        while let id = queue.first {
            queue.removeFirst()
            guard !visited.contains(id) else { continue }
            visited.insert(id)

            for neighbor in adjacency[id, default: []] where !visited.contains(neighbor) {
                queue.append(neighbor)
            }
        }

        return visited
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

    func beginPointerInteractionForTesting(at point: CGPoint, viewPoint: CGPoint? = nil) {
        beginPointerInteraction(at: point, viewPoint: viewPoint ?? point)
    }

    func movePointerInteractionForTesting(to point: CGPoint, viewPoint: CGPoint? = nil) {
        movePointerInteraction(to: point, viewPoint: viewPoint ?? point)
    }

    func endPointerInteractionForTesting(at point: CGPoint, viewPoint: CGPoint? = nil) {
        endPointerInteraction(at: point, viewPoint: viewPoint ?? point)
    }

    var cameraPositionForTesting: CGPoint {
        cameraNode.position
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
