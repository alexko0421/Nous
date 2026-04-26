import SpriteKit
import SwiftUI

final class GalaxyScene: SKScene {

    private struct NodeColor {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
            self.red = red / 255
            self.green = green / 255
            self.blue = blue / 255
        }

        func skColor(alpha: CGFloat = 1) -> SKColor {
            SKColor(red: red, green: green, blue: blue, alpha: alpha)
        }

        func mixed(with other: NodeColor, fraction: CGFloat, alpha: CGFloat = 1) -> SKColor {
            let amount = fraction.clamped(to: 0...1)
            return SKColor(
                red: red + (other.red - red) * amount,
                green: green + (other.green - green) * amount,
                blue: blue + (other.blue - blue) * amount,
                alpha: alpha
            )
        }
    }

    private static let paperLight = NodeColor(246, 238, 224)
    private static let ink = NodeColor(231, 212, 179)
    private static let mutedInk = NodeColor(184, 154, 122)
    private static let lonelyGray = NodeColor(138, 138, 138)
    private static let focusTerracotta = NodeColor(176, 117, 90)
    private static let semanticSage = NodeColor(129, 154, 132)

    private static let morandiNodePalette: [NodeColor] = [
        NodeColor(231, 212, 179), // warm oat
        NodeColor(209, 177, 153), // dusty almond
        NodeColor(184, 154, 122), // camel
        NodeColor(161, 130, 102), // taupe
        NodeColor(140, 109, 79),  // walnut
        NodeColor(123, 167, 188), // stone blue
        NodeColor(129, 154, 132), // sage
        NodeColor(168, 181, 160), // moss fog
        NodeColor(155, 142, 196), // lavender gray
        NodeColor(176, 117, 90),  // terracotta
        NodeColor(150, 151, 137), // olive gray
        NodeColor(196, 176, 152)  // warm gray
    ]

    var graphNodes: [NousNode] = []
    var graphEdges: [NodeEdge] = []
    var positions: [UUID: GraphPosition] = [:]
    var selectedNodeId: UUID?
    var onNodeTapped: ((UUID) -> Void)?
    var onNodeMoved: ((UUID, GraphPosition) -> Void)?

    var constellations: [Constellation] = []
    var dominantConstellationId: UUID?
    var revealedConstellationIds: Set<UUID> = []
    var toggleAllVisible: Bool = false

    /// Soft cap on simultaneously-visible halos — see priority tiers in
    /// visibleHaloIds(). Tap-revealed always renders even past this cap;
    /// dominant gets a reserved slot when present; remainder fills with
    /// toggle-revealed halos by confidence desc.
    var maxVisibleHalos: Int = 8

    // Drag-physics state placeholder. Set true while user is dragging
    // or simulation is settling; flipped back to false on sleep.
    // Task 23 wires the actual state machine.
    var isSimActive: Bool = false

    /// True while the in-scene physics simulation is the source of truth
    /// for node positions. While true, GalaxySceneContainer suppresses its
    /// usual `scene.positions = vm.positions` copy so SwiftUI rerenders
    /// (selection changes, sheet open) cannot snap nodes back to a stale
    /// view-model snapshot mid-drag.
    ///
    /// Lifecycle (Task 23):
    ///   - mouseDown on a node → set true
    ///   - update(_:) runs the sim while true
    ///   - sleep watchdog flips back to false (after onSimulationSettled
    ///     hands settled positions to the ViewModel)
    var simulationOwnsPositions: Bool = false

    // MARK: - Live drag-physics state

    /// Per-node velocity for the live sim. Zeroed on sleep (Codex round-1
    /// review: defends against floating-point jitter at the velocity floor).
    private var nodeVelocities: [UUID: GraphPosition] = [:]

    /// The dragged node's id while user is holding mouse down. The sim
    /// loop skips applying velocity to this node — its position is
    /// kinematic (mouse-driven). Reset to nil on mouseUp.
    private var kinematicNodeId: UUID?

    /// Sleep watchdog frame counters (Codex round-1 issue):
    ///   - softWatchdog: count of consecutive frames with max(|v|) below
    ///     threshold. Triggers sleep at softWatchdogFrames.
    ///   - hardWatchdog: count of frames since mouseUp. Triggers sleep at
    ///     hardTimeoutFrames regardless of velocity (defends against
    ///     pathological jitter).
    private var framesUnderVelocityThreshold: Int = 0
    private var framesSinceMouseUp: Int = 0
    /// Absolute frame counter since sim wake. Forces sleep regardless of
    /// kinematic / velocity state if the sim runs longer than the cap —
    /// safety net against scenarios where mouseUp never fires (e.g.,
    /// release outside the SKView, lost focus, drag canceled by the OS)
    /// that would otherwise leave isSimActive stuck true and the main
    /// thread starved by 120fps O(N²) physics.
    private var totalSimFrames: Int = 0

    /// Tunables (mirror GraphEngine.computeLayout defaults).
    private let simRepulsion: Float = 12000
    private let simAttraction: Float = 0.004
    private let simDamping: Float = 0.86
    /// Constellation pairwise attraction = 0.2× semantic edge strength
    /// (spec §7.3 "weak attraction").
    private let constellationAttractionFactor: Float = 0.2
    private let velocityThreshold: Float = 0.5
    private let softWatchdogFrames: Int = 30
    private let hardTimeoutFrames: Int = 90
    /// Absolute cap, ~5s at 120fps. Prevents stuck-on sim no matter what.
    private let absoluteMaxSimFrames: Int = 600

    /// Called when the sleep watchdog flips isSimActive false. Receives the
    /// final settled positions; consumer (GalaxyViewModel) persists via
    /// PositionSnapshotStore. Invoked on the main thread (SpriteKit's
    /// update(_:) callback already runs on main).
    var onSimulationSettled: (([UUID: GraphPosition]) -> Void)?

    private var haloEffectNodes: [UUID: SKEffectNode] = [:]
    private var haloMemberSprites: [UUID: [SKSpriteNode]] = [:]
    private var nebulaContainer: SKNode?

    private var cameraNode: SKCameraNode = SKCameraNode()
    private var draggedNode: SKNode?
    private var draggedNodeId: UUID?
    private var dragStartPosition: CGPoint = .zero

    /// Camera-pan state: true while the user is dragging on empty space
    /// (no node hit) to translate the camera. Mutually exclusive with
    /// node drag; mouseDown picks one based on whether the cursor hit
    /// a node.
    private var isPanning: Bool = false
    private var panLastWindowLocation: CGPoint = .zero
    private var edgeSprites: [UUID: SKShapeNode] = [:]
    private var nodeSprites: [UUID: SKShapeNode] = [:]
    private var nodeLabels: [UUID: SKLabelNode] = [:]
    private var nodeHitRadii: [UUID: CGFloat] = [:]
    private var draggedNodeOriginalZPosition: CGFloat = 1
    private var dragLatestPosition: GraphPosition?

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
        children.forEach { node in
            if node !== cameraNode { node.removeFromParent() }
        }
        edgeSprites.removeAll()
        nodeSprites.removeAll()
        nodeLabels.removeAll()
        nodeHitRadii.removeAll()
        haloEffectNodes.removeAll()
        haloMemberSprites.removeAll()
        nebulaContainer = nil

        drawNebula()
        drawEdges()
        drawNodes()
        rebuildHalos()
        updateLabelVisibility()
    }

    func syncPositions() {
        for (id, sprite) in nodeSprites {
            guard let position = positions[id] else { continue }
            sprite.position = CGPoint(x: CGFloat(position.x), y: CGFloat(position.y))
        }

        updateEdgePaths()

        // Reflow halo sprite positions to follow their member nodes
        for (cid, sprites) in haloMemberSprites {
            guard let c = constellations.first(where: { $0.id == cid }) else { continue }
            for (idx, nid) in c.memberNodeIds.enumerated() where idx < sprites.count {
                guard let pos = positions[nid] else { continue }
                sprites[idx].position = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
            }
        }

        updateLabelVisibility()
    }

    // MARK: - Live Drag Physics

    override func update(_ currentTime: TimeInterval) {
        guard isSimActive else { return }

        // Absolute safety: never let the sim run longer than absoluteMaxSimFrames
        // regardless of kinematic / velocity state. Defends against scenarios
        // where mouseUp never fires (release outside SKView, focus loss, OS
        // drag cancel) which would otherwise leave the main thread starved.
        totalSimFrames += 1
        if totalSimFrames >= absoluteMaxSimFrames {
            putSimToSleep()
            return
        }

        let nodeIds = Array(positions.keys)
        let kinematic = kinematicNodeId

        // 1. Repulsion (O(N²)) — every pair of nodes pushes apart inversely
        //    proportional to distance squared.
        for i in 0..<nodeIds.count {
            for j in (i + 1)..<nodeIds.count {
                let idA = nodeIds[i]
                let idB = nodeIds[j]
                guard let pA = positions[idA], let pB = positions[idB] else { continue }
                let dx = pA.x - pB.x
                let dy = pA.y - pB.y
                let distSq = max(dx * dx + dy * dy, 1.0)
                let force = simRepulsion / distSq
                let dist = sqrt(distSq)
                let fx = force * dx / dist
                let fy = force * dy / dist
                nodeVelocities[idA, default: GraphPosition(x: 0, y: 0)].x += fx
                nodeVelocities[idA, default: GraphPosition(x: 0, y: 0)].y += fy
                nodeVelocities[idB, default: GraphPosition(x: 0, y: 0)].x -= fx
                nodeVelocities[idB, default: GraphPosition(x: 0, y: 0)].y -= fy
            }
        }

        // 2. Edge attraction (manual + semantic; .shared was deleted in Task 1+3).
        for edge in graphEdges {
            guard let pA = positions[edge.sourceId], let pB = positions[edge.targetId] else { continue }
            let dx = pA.x - pB.x
            let dy = pA.y - pB.y
            let fx = simAttraction * edge.strength * dx
            let fy = simAttraction * edge.strength * dy
            nodeVelocities[edge.sourceId, default: GraphPosition(x: 0, y: 0)].x -= fx
            nodeVelocities[edge.sourceId, default: GraphPosition(x: 0, y: 0)].y -= fy
            nodeVelocities[edge.targetId, default: GraphPosition(x: 0, y: 0)].x += fx
            nodeVelocities[edge.targetId, default: GraphPosition(x: 0, y: 0)].y += fy
        }

        // 3. Constellation pairwise weak attraction (post-K=2 cap by §3.3).
        //    Strength = 0.3 (matches the spec's "moderate" virtual strength)
        //    × constellationAttractionFactor (0.2× semantic) = 0.06 effective.
        let constellationStrength: Float = 0.3
        for c in constellations {
            let members = c.memberNodeIds
            guard members.count >= 2 else { continue }
            for i in 0..<members.count {
                for j in (i + 1)..<members.count {
                    let idA = members[i]
                    let idB = members[j]
                    guard let pA = positions[idA], let pB = positions[idB] else { continue }
                    let dx = pA.x - pB.x
                    let dy = pA.y - pB.y
                    let fx = simAttraction * constellationAttractionFactor * constellationStrength * dx
                    let fy = simAttraction * constellationAttractionFactor * constellationStrength * dy
                    nodeVelocities[idA, default: GraphPosition(x: 0, y: 0)].x -= fx
                    nodeVelocities[idA, default: GraphPosition(x: 0, y: 0)].y -= fy
                    nodeVelocities[idB, default: GraphPosition(x: 0, y: 0)].x += fx
                    nodeVelocities[idB, default: GraphPosition(x: 0, y: 0)].y += fy
                }
            }
        }

        // 4. Apply velocity (skip kinematic node — mouse drives its position).
        var maxVelMagnitude: Float = 0
        for id in nodeIds {
            if id == kinematic {
                nodeVelocities[id] = GraphPosition(x: 0, y: 0)
                continue
            }
            var v = nodeVelocities[id, default: GraphPosition(x: 0, y: 0)]
            v.x *= simDamping
            v.y *= simDamping
            nodeVelocities[id] = v
            positions[id]!.x += v.x
            positions[id]!.y += v.y
            let mag = sqrt(v.x * v.x + v.y * v.y)
            if mag > maxVelMagnitude { maxVelMagnitude = mag }
        }

        // 5. Reflect new positions in sprite/halo positions.
        syncPositions()

        // 6. Sleep watchdog — only after mouseUp (while user is dragging,
        //    don't try to settle).
        if kinematicNodeId == nil {
            framesSinceMouseUp += 1
            if maxVelMagnitude < velocityThreshold {
                framesUnderVelocityThreshold += 1
            } else {
                framesUnderVelocityThreshold = 0
            }
            if framesUnderVelocityThreshold >= softWatchdogFrames || framesSinceMouseUp >= hardTimeoutFrames {
                putSimToSleep()
            }
        } else {
            framesSinceMouseUp = 0
        }
    }

    private func putSimToSleep() {
        // Zero velocities (Codex jitter guard)
        for k in nodeVelocities.keys {
            nodeVelocities[k] = GraphPosition(x: 0, y: 0)
        }
        // Defensive: clear kinematic too in case sleep was forced via the
        // absolute timeout while a drag was somehow still in flight.
        kinematicNodeId = nil
        isSimActive = false
        framesUnderVelocityThreshold = 0
        framesSinceMouseUp = 0
        totalSimFrames = 0

        // Hand settled positions to the consumer (Task 25 wires this into
        // GalaxyViewModel.handleSimulationSettled).
        onSimulationSettled?(positions)

        // Release ownership so SwiftUI rerenders can copy in again.
        simulationOwnsPositions = false

        // Re-enable rasterization on halos (Task 19 ties this to isSimActive).
        for (_, effect) in haloEffectNodes {
            effect.shouldRasterize = true
        }
    }

    // MARK: - Halo Rendering

    /// Resolves which constellations to render halos for, respecting the
    /// 8-cap with priority tiers:
    ///   1. Tap-revealed (no cap applies — user explicit intent overrides everything)
    ///   2. Dominant ambient (reserved 1 slot if exists)
    ///   3. Toggle-revealed remainder (fills slots in claim.confidence desc)
    private func visibleHaloIds() -> [UUID] {
        let tap = revealedConstellationIds  // tier 1: always renders
        var pinned = Array(tap)

        // tier 2: dominant reserved slot (if not already in tap)
        if let dom = dominantConstellationId, !tap.contains(dom) {
            pinned.append(dom)
        }

        // tier 3: toggle-revealed remainder by confidence
        let pinnedSet = Set(pinned)
        var remainder: [Constellation] = []
        if toggleAllVisible {
            remainder = constellations
                .filter { !pinnedSet.contains($0.id) }
                .sorted { $0.confidence > $1.confidence }
        }

        let slotsLeft = max(0, maxVisibleHalos - pinned.count)
        let take = remainder.prefix(slotsLeft).map(\.id)
        return pinned + take
    }

    /// Alpha tier for a halo based on current scene state.
    /// Tiers (per spec §5.3):
    ///   - tap-revealed: 0.55
    ///   - dominant ambient (reserved slot): 0.08 — even in toggle-all mode,
    ///     dominant keeps its ambient alpha so it reads visually distinct from
    ///     the toggle tier
    ///   - toggle-revealed: 0.35
    ///   - hidden: 0.0
    func haloAlpha(for constellationId: UUID) -> CGFloat {
        if revealedConstellationIds.contains(constellationId) { return 0.55 }
        if dominantConstellationId == constellationId { return 0.08 }
        if toggleAllVisible { return 0.35 }
        return 0
    }

    private func rebuildHalos() {
        // Tear down existing halos
        for (_, effect) in haloEffectNodes { effect.removeFromParent() }
        haloEffectNodes.removeAll()
        haloMemberSprites.removeAll()

        let visibleIds = Set(visibleHaloIds())

        for c in constellations where visibleIds.contains(c.id) {
            let effect = SKEffectNode()
            // Rasterize when sim is asleep (sprite positions stable, cheap to
            // composite); turn off during active drag sim (sprites move per
            // frame, rasterization would re-cache constantly and waste GPU).
            effect.shouldRasterize = !isSimActive
            effect.zPosition = -2  // beneath edges (-1) and nodes
            effect.alpha = 0  // start at 0; updateHaloAlphas() animates to target

            var sprites: [SKSpriteNode] = []
            for nid in c.memberNodeIds {
                guard let pos = positions[nid] else { continue }
                let sprite = SKSpriteNode(texture: HaloTexture.cached)
                sprite.position = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
                sprite.size = HaloTexture.cached.size()
                effect.addChild(sprite)
                sprites.append(sprite)
            }

            haloEffectNodes[c.id] = effect
            haloMemberSprites[c.id] = sprites
            addChild(effect)
        }
    }

    /// Animates halo alpha to the current state's target alpha (per
    /// haloAlpha) over 0.6s ease-in-out. Used both after rebuildScene()
    /// (to animate from alpha 0 to target) and when revealed/toggle state
    /// changes without changing the visible halo set.
    ///
    /// When `staggered` is true, halos fade in sequentially by distance
    /// from scene center (closest first, 80ms between each) — like dusk
    /// star-rise. Used on toggleAllVisible transitions.
    ///
    /// If the visible set changes (a halo appears or disappears), call
    /// rebuildScene() first, then call this to animate into view.
    func updateHaloAlphas(staggered: Bool = false) {
        let visible = visibleHaloIds()

        // Sort by distance from scene center so closer halos fade in first.
        let sortedIds: [UUID] = staggered
            ? visible.sorted { distanceFromCenter(constellationId: $0) < distanceFromCenter(constellationId: $1) }
            : visible

        for (idx, cid) in sortedIds.enumerated() {
            guard let effect = haloEffectNodes[cid] else { continue }
            let target = haloAlpha(for: cid)
            let delay = staggered ? Double(idx) * 0.08 : 0
            effect.removeAction(forKey: "haloAlpha")
            let fade = SKAction.fadeAlpha(to: target, duration: 0.6)
            fade.timingMode = .easeInEaseOut
            let action = SKAction.sequence([
                .wait(forDuration: delay),
                fade
            ])
            effect.run(action, withKey: "haloAlpha")
        }
    }

    private func distanceFromCenter(constellationId: UUID) -> CGFloat {
        guard let c = constellations.first(where: { $0.id == constellationId }) else {
            return .greatestFiniteMagnitude
        }
        let positions = c.memberNodeIds.compactMap { self.positions[$0] }
        guard !positions.isEmpty else { return .greatestFiniteMagnitude }
        let mx = positions.map { CGFloat($0.x) }.reduce(0, +) / CGFloat(positions.count)
        let my = positions.map { CGFloat($0.y) }.reduce(0, +) / CGFloat(positions.count)
        return sqrt(mx * mx + my * my)
    }

    private func drawNebula() {
        let container = SKNode()
        container.zPosition = -3  // beneath halos (-2) and edges (-1)
        container.alpha = NebulaLayer.alphaForZoom(cameraScale: cameraNode.xScale)
        nebulaContainer = container

        // extent radius = larger of (sceneWidth/2, sceneHeight/2), or fallback
        let extent = max(size.width, size.height) * 0.5
        let safeExtent = extent > 0 ? extent : 400

        let patches = NebulaLayer.freeDistributionPatches(
            nodeCount: graphNodes.count,
            extentRadius: safeExtent
        )
        for patch in patches {
            for layer in patch.layers {
                // Soft ellipse with radial alpha falloff. SpriteKit doesn't have
                // a built-in radial gradient shape, so approximate via stacked
                // SKShapeNode ellipses with descending alpha — cheaper than
                // CIFilter for a static atmospheric layer.
                let ellipseRect = CGRect(
                    x: -layer.radiusX, y: -layer.radiusY,
                    width: layer.radiusX * 2, height: layer.radiusY * 2
                )
                let shape = SKShapeNode(ellipseIn: ellipseRect)
                shape.position = CGPoint(x: patch.centerX + layer.offsetX, y: patch.centerY + layer.offsetY)
                shape.zRotation = layer.rotation
                shape.fillColor = layer.color
                shape.strokeColor = .clear
                shape.alpha = layer.peakOpacity
                container.addChild(shape)
            }
        }
        addChild(container)
    }

    private func drawEdges() {
        let focusedNodeId = draggedNodeId ?? selectedNodeId

        for edge in graphEdges {
            guard
                let srcPos = positions[edge.sourceId],
                let tgtPos = positions[edge.targetId]
            else { continue }

            let start = CGPoint(x: CGFloat(srcPos.x), y: CGFloat(srcPos.y))
            let end = CGPoint(x: CGFloat(tgtPos.x), y: CGFloat(tgtPos.y))
            let path = softenedPath(from: start, to: end)

            let line = SKShapeNode(path: path)
            let isFocusedEdge = edge.sourceId == focusedNodeId || edge.targetId == focusedNodeId
            let hasFocus = focusedNodeId != nil
            let strength = CGFloat(edge.strength).clamped(to: 0...1)
            let color = edgeColor(for: edge)

            line.lineCap = .round
            line.lineJoin = .round
            line.strokeColor = strokeColor(for: edge, baseColor: color, strength: strength, isFocused: isFocusedEdge)
            line.lineWidth = lineWidth(for: edge, strength: strength, isFocused: isFocusedEdge)
            line.alpha = hasFocus && !isFocusedEdge ? 0.10 : 1
            line.glowWidth = isFocusedEdge ? 0.7 : 0
            line.zPosition = -1

            edgeSprites[edge.id] = line
            addChild(line)
        }
    }

    private func drawNodes() {
        let degreeByNodeId = connectionCounts()
        let focusedNodeId = draggedNodeId ?? selectedNodeId
        let connectedNodeIds = connectedNodeIds(for: focusedNodeId)
        let hasFocus = focusedNodeId != nil

        for node in graphNodes {
            guard let pos = positions[node.id] else { continue }

            let degree = degreeByNodeId[node.id, default: 0]
            let isLonely = degree == 0
            let radius = nodeRadius(for: node, degree: degree, isLonely: isLonely)
            let isSelected = node.id == selectedNodeId
            let isDragged = node.id == draggedNodeId
            let isFocused = isSelected || isDragged
            let isConnectedToFocus = connectedNodeIds.contains(node.id)
            let isDimmed = hasFocus && !isFocused && !isConnectedToFocus
            let color = isLonely ? Self.lonelyGray : nodeColor(for: node)

            let circle = SKShapeNode(circleOfRadius: CGFloat(radius))
            circle.position = CGPoint(x: CGFloat(pos.x), y: CGFloat(pos.y))
            circle.fillColor = fillColor(
                for: node,
                baseColor: color,
                isLonely: isLonely,
                isFocused: isFocused,
                isConnected: isConnectedToFocus
            )
            circle.strokeColor = outlineColor(
                for: node,
                baseColor: color,
                isLonely: isLonely,
                isFocused: isFocused,
                isConnected: isConnectedToFocus
            )
            circle.lineWidth = isFocused ? 1.25 : isConnectedToFocus || node.isFavorite ? 0.95 : 0.6
            circle.glowWidth = 0
            circle.alpha = isDimmed ? 0.24 : 1
            circle.name = node.id.uuidString
            circle.zPosition = isFocused ? 6 : isConnectedToFocus ? 4 : isLonely ? 1 : 2

            if isFocused || isConnectedToFocus || node.isFavorite {
                let ring = SKShapeNode(circleOfRadius: CGFloat(radius + (isFocused ? 7 : 4)))
                ring.strokeColor = ringColor(
                    baseColor: color,
                    isFocused: isFocused,
                    isConnected: isConnectedToFocus
                )
                ring.lineWidth = isFocused ? 1.0 : 0.7
                ring.fillColor = .clear
                ring.alpha = isDimmed ? 0.18 : 1
                ring.zPosition = -0.2
                circle.addChild(ring)
            }

            let titleLabel = SKLabelNode(text: displayTitle(for: node))
            titleLabel.fontName = "SF Pro Text"
            titleLabel.fontSize = isFocused ? 11.6 : 10.6
            titleLabel.fontColor = labelColor(isFocused: isFocused, isConnected: isConnectedToFocus, isDimmed: isDimmed)
            titleLabel.verticalAlignmentMode = .top
            titleLabel.horizontalAlignmentMode = .center
            titleLabel.position = CGPoint(x: 0, y: -(CGFloat(radius) + 7))
            titleLabel.zPosition = 2
            circle.addChild(titleLabel)

            addChild(circle)
            nodeSprites[node.id] = circle
            nodeLabels[node.id] = titleLabel
            nodeHitRadii[node.id] = max(18, radius + 10)
        }
    }

    private func softenedPath(from start: CGPoint, to end: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: start)

        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = max(sqrt(dx * dx + dy * dy), 1)
        let bend = min(distance * 0.045, 18)
        let control = CGPoint(
            x: (start.x + end.x) * 0.5 - dy / distance * bend,
            y: (start.y + end.y) * 0.5 + dx / distance * bend
        )

        path.addQuadCurve(to: end, control: control)
        return path
    }

    private func connectionCounts() -> [UUID: Int] {
        var counts: [UUID: Int] = [:]

        for edge in graphEdges {
            counts[edge.sourceId, default: 0] += 1
            counts[edge.targetId, default: 0] += 1
        }

        return counts
    }

    private func nodeRadius(for node: NousNode, degree: Int, isLonely: Bool) -> CGFloat {
        if isLonely {
            return node.isFavorite ? 5.6 : 4.8
        }

        let contentWeight = min(sqrt(Double(node.content.count)) * 0.08, 1.8)
        let degreeWeight = min(Double(degree) * 0.32, 2.4)
        let favoriteWeight = node.isFavorite ? 0.9 : 0
        return CGFloat(7.0 + contentWeight + degreeWeight + favoriteWeight)
    }

    private func fillColor(
        for node: NousNode,
        baseColor: NodeColor,
        isLonely: Bool,
        isFocused: Bool,
        isConnected: Bool
    ) -> SKColor {
        if isLonely && !isFocused {
            return baseColor.skColor(alpha: 0.58)
        }

        if isFocused {
            return baseColor.mixed(with: Self.paperLight, fraction: 0.24, alpha: 0.98)
        }

        if isConnected {
            return baseColor.mixed(with: Self.paperLight, fraction: 0.16, alpha: 0.92)
        }

        let typeLift: CGFloat = node.type == .conversation ? 0.10 : 0.18
        return baseColor.mixed(with: Self.paperLight, fraction: typeLift, alpha: 0.82)
    }

    private func outlineColor(
        for node: NousNode,
        baseColor: NodeColor,
        isLonely: Bool,
        isFocused: Bool,
        isConnected: Bool
    ) -> SKColor {
        if isFocused {
            return Self.focusTerracotta.skColor(alpha: 0.92)
        }

        if node.isFavorite {
            return Self.focusTerracotta.skColor(alpha: 0.52)
        }

        if isLonely {
            return Self.ink.skColor(alpha: 0.13)
        }

        if isConnected {
            return baseColor.mixed(with: Self.ink, fraction: 0.18, alpha: 0.42)
        }

        return Self.ink.skColor(alpha: 0.14)
    }

    private func labelColor(isFocused: Bool, isConnected: Bool, isDimmed: Bool) -> SKColor {
        if isDimmed {
            return Self.mutedInk.skColor(alpha: 0.28)
        }

        if isFocused {
            return Self.ink.skColor(alpha: 0.96)
        }

        if isConnected {
            return Self.ink.skColor(alpha: 0.78)
        }

        return Self.mutedInk.skColor(alpha: 0.62)
    }

    private func ringColor(baseColor: NodeColor, isFocused: Bool, isConnected: Bool) -> SKColor {
        if isFocused {
            return Self.focusTerracotta.skColor(alpha: 0.34)
        }

        if isConnected {
            return baseColor.mixed(with: Self.paperLight, fraction: 0.25, alpha: 0.24)
        }

        return baseColor.skColor(alpha: 0.16)
    }

    private func strokeColor(for edge: NodeEdge, baseColor: NodeColor, strength: CGFloat, isFocused: Bool) -> SKColor {
        switch edge.type {
        case .manual:
            return baseColor.mixed(with: Self.paperLight, fraction: 0.20, alpha: isFocused ? 0.74 : 0.32)
        case .semantic:
            return baseColor.mixed(with: Self.paperLight, fraction: 0.22, alpha: isFocused ? 0.66 : 0.20 + strength * 0.10)
        }
    }

    private func lineWidth(for edge: NodeEdge, strength: CGFloat, isFocused: Bool) -> CGFloat {
        switch edge.type {
        case .manual:
            return isFocused ? 1.55 : 0.9
        case .semantic:
            return isFocused ? 1.35 : 0.72 + strength * 0.14
        }
    }

    private func nodeColor(for node: NousNode) -> NodeColor {
        Self.morandiNodePalette[stablePaletteIndex(for: node.id, salt: node.projectId)]
    }

    private func edgeColor(for edge: NodeEdge) -> NodeColor {
        switch edge.type {
        case .manual:
            return nodeColor(for: edge.sourceId)
        case .semantic:
            return Self.semanticSage
        }
    }

    private func nodeColor(for id: UUID) -> NodeColor {
        Self.morandiNodePalette[stablePaletteIndex(for: id, salt: nil)]
    }

    private func stablePaletteIndex(for id: UUID, salt: UUID?) -> Int {
        let key = [salt?.uuidString, id.uuidString]
            .compactMap { $0 }
            .joined(separator: "-")
        var hash: UInt64 = 14_695_981_039_346_656_037

        for scalar in key.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= 1_099_511_628_211
        }

        return Int(hash % UInt64(Self.morandiNodePalette.count))
    }

    private func connectedNodeIds(for focusId: UUID?) -> Set<UUID> {
        guard let focusId else { return [] }
        var ids: Set<UUID> = []

        for edge in graphEdges {
            if edge.sourceId == focusId {
                ids.insert(edge.targetId)
            } else if edge.targetId == focusId {
                ids.insert(edge.sourceId)
            }
        }

        return ids
    }

    private func updateLabelVisibility() {
        let degreeByNodeId = connectionCounts()
        let focusedNodeId = draggedNodeId ?? selectedNodeId
        let connectedNodeIds = connectedNodeIds(for: focusedNodeId)
        let isZoomedOut = cameraNode.xScale > 1.30
        let isZoomedIn = cameraNode.xScale < 0.72

        for node in graphNodes {
            guard let label = nodeLabels[node.id] else { continue }
            let isFocused = node.id == focusedNodeId
            let isConnected = connectedNodeIds.contains(node.id)
            let isLonely = degreeByNodeId[node.id, default: 0] == 0

            if isFocused {
                label.alpha = 1.0
            } else if isConnected {
                label.alpha = isZoomedOut ? 0.34 : 0.76
            } else if isLonely {
                label.alpha = isZoomedIn ? 0.46 : 0.0
            } else {
                label.alpha = isZoomedOut ? 0.0 : 0.50
            }
        }

        nebulaContainer?.alpha = NebulaLayer.alphaForZoom(cameraScale: cameraNode.xScale)
    }

    private func truncated(_ text: String, maxLen: Int) -> String {
        guard text.count > maxLen else { return text }
        return String(text.prefix(maxLen)) + "..."
    }

    private func displayTitle(for node: NousNode) -> String {
        truncated(node.title.isEmpty ? "Untitled" : node.title, maxLen: 22)
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

    private func clampedScenePoint(_ point: CGPoint) -> CGPoint {
        let xLimit = max(size.width * 0.48, 360)
        let yLimit = max(size.height * 0.44, 280)
        return CGPoint(
            x: point.x.clamped(to: -xLimit...xLimit),
            y: point.y.clamped(to: -yLimit...yLimit)
        )
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
            line.path = softenedPath(from: start, to: end)
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = scenePoint(from: event)
        if let (_, id) = nodeAt(point: point) {
            draggedNodeId = id
            dragLatestPosition = nil
            rebuildScene()

            guard let sprite = nodeSprites[id] else { return }
            draggedNode = sprite
            draggedNodeOriginalZPosition = sprite.zPosition
            sprite.zPosition = 8
            sprite.removeAction(forKey: "dragScale")
            let scaleUp = SKAction.scale(to: 1.18, duration: 0.20)
            scaleUp.timingMode = .easeOut
            sprite.run(scaleUp, withKey: "dragScale")
            dragStartPosition = point

            // Wake the live sim. update(_:) starts running per-frame
            // physics; the dragged node is kinematic (mouse-driven), other
            // nodes feel forces and reflow.
            kinematicNodeId = id
            isSimActive = true
            simulationOwnsPositions = true
            framesUnderVelocityThreshold = 0
            framesSinceMouseUp = 0
            totalSimFrames = 0
            // Halos must un-rasterize while sprites move per frame.
            for (_, effect) in haloEffectNodes {
                effect.shouldRasterize = false
            }
        } else {
            // Empty-space click → start camera pan. Track in window
            // coordinates so deltas stay correct as the camera moves
            // (scene-coord deltas would shift mid-drag).
            isPanning = true
            panLastWindowLocation = event.locationInWindow
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanning {
            // Translate camera by the inverse of the cursor delta (scaled by
            // camera zoom) so the world appears to follow the cursor.
            let now = event.locationInWindow
            let dx = now.x - panLastWindowLocation.x
            let dy = now.y - panLastWindowLocation.y
            panLastWindowLocation = now
            let scale = cameraNode.xScale
            cameraNode.position.x -= dx * scale
            cameraNode.position.y -= dy * scale
            return
        }

        guard let draggedNodeId else { return }
        let point = clampedScenePoint(scenePoint(from: event))
        let position = GraphPosition(x: Float(point.x), y: Float(point.y))
        positions[draggedNodeId] = position
        dragLatestPosition = position

        if let sprite = nodeSprites[draggedNodeId] {
            sprite.position = point
            sprite.zPosition = 8
            draggedNode = sprite
        } else {
            draggedNode?.position = point
        }

        updateEdgePaths()
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            isPanning = false
            return
        }

        guard let dragged = draggedNode else {
            draggedNodeId = nil
            dragLatestPosition = nil
            kinematicNodeId = nil
            return
        }

        let point = scenePoint(from: event)
        let dx = point.x - dragStartPosition.x
        let dy = point.y - dragStartPosition.y
        let distance = sqrt(dx * dx + dy * dy)
        let releasedNodeId = draggedNodeId ?? dragged.name.flatMap(UUID.init(uuidString:))
        let finalPosition = dragLatestPosition

        dragged.removeAction(forKey: "dragScale")
        let scaleDown = SKAction.scale(to: 1.0, duration: 0.20)
        scaleDown.timingMode = .easeIn
        dragged.run(scaleDown, withKey: "dragScale")
        dragged.zPosition = draggedNodeOriginalZPosition
        draggedNode = nil
        draggedNodeId = nil
        dragLatestPosition = nil

        // Clear kinematic but keep the sim running — the watchdog inside
        // update(_:) will settle and call onSimulationSettled. We
        // intentionally do NOT call rebuildScene() while the sim is
        // active: that would tear down halo SKEffectNodes mid-animation.
        kinematicNodeId = nil
        framesSinceMouseUp = 0
        framesUnderVelocityThreshold = 0

        if distance < 5, let releasedNodeId {
            onNodeTapped?(releasedNodeId)
            // Tap, not drag. The sim hasn't accumulated meaningful velocity
            // (kinematic node was pinned to cursor with ~0 motion). Skip
            // running the watchdog and settle instantly to avoid a quarter-
            // second of dead air after a tap.
            putSimToSleep()
            rebuildScene()
        } else if let releasedNodeId, let finalPosition {
            onNodeMoved?(releasedNodeId, finalPosition)
            // Sim continues to run; rebuildScene will be triggered by the
            // SwiftUI rerender after onSimulationSettled hands settled
            // positions back to the ViewModel (Task 25 wires this).
        }
    }

    // MARK: - Zoom

    override func scrollWheel(with event: NSEvent) {
        let zoomDelta = event.deltaY * 0.01
        let newScale = (cameraNode.xScale - zoomDelta).clamped(to: 0.35...2.8)
        cameraNode.setScale(newScale)
        updateLabelVisibility()
    }

    override func magnify(with event: NSEvent) {
        let newScale = (cameraNode.xScale * (1 - event.magnification)).clamped(to: 0.35...2.8)
        cameraNode.setScale(newScale)
        updateLabelVisibility()
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
