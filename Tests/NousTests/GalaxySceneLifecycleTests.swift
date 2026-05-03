import SpriteKit
import XCTest
@testable import Nous

@MainActor
final class GalaxySceneLifecycleTests: XCTestCase {
    func testSceneCanMoveToAViewMoreThanOnceWithoutDuplicatingCamera() {
        let scene = GalaxyScene()
        let firstView = SKView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let secondView = SKView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))

        scene.didMove(to: firstView)
        scene.didMove(to: secondView)

        let cameras = scene.children.compactMap { $0 as? SKCameraNode }
        XCTAssertEqual(cameras.count, 1)
        XCTAssertTrue(scene.camera === cameras.first)
        XCTAssertTrue(cameras.first?.parent === scene)
    }

    func testInteractiveGalaxyViewDoesNotTurnGraphDragsIntoWindowDrags() {
        let view = InteractiveGalaxySKView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))

        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }

    func testSceneCanHitTestAnEdgeNearTheLine() {
        let sourceId = UUID()
        let targetId = UUID()
        let edge = NodeEdge(sourceId: sourceId, targetId: targetId, strength: 0.8, type: .semantic)
        let scene = GalaxyScene()
        scene.size = CGSize(width: 480, height: 320)
        scene.graphEdges = [edge]
        scene.positions = [
            sourceId: GraphPosition(x: -80, y: 0),
            targetId: GraphPosition(x: 80, y: 0)
        ]
        scene.rebuildScene()

        XCTAssertEqual(scene.edgeId(at: CGPoint(x: 0, y: 5)), edge.id)
        XCTAssertNil(scene.edgeId(at: CGPoint(x: 0, y: 44)))
    }

    func testNormalNodesRenderWithoutNeonGlow() throws {
        let node = NousNode(type: .conversation, title: "Quiet node")
        let scene = GalaxyScene()
        scene.size = CGSize(width: 480, height: 320)
        scene.graphNodes = [node]
        scene.positions = [
            node.id: GraphPosition(x: 0, y: 0)
        ]
        scene.rebuildScene()

        let nodeShape = try XCTUnwrap(scene.children.compactMap { $0 as? SKShapeNode }.first { $0.name == node.id.uuidString })
        XCTAssertEqual(nodeShape.glowWidth, 0)
    }

    func testNormalNodesRenderAsSolidShapes() throws {
        let node = NousNode(type: .conversation, title: "Solid node")
        let scene = GalaxyScene()
        scene.size = CGSize(width: 480, height: 320)
        scene.graphNodes = [node]
        scene.positions = [
            node.id: GraphPosition(x: 0, y: 0)
        ]
        scene.rebuildScene()

        let nodeShape = try XCTUnwrap(scene.children.compactMap { $0 as? SKShapeNode }.first { $0.name == node.id.uuidString })
        XCTAssertGreaterThanOrEqual(nodeShape.fillColor.alphaComponent, 0.92)
    }

    func testGalaxyNodesUseNeutralFillSoRelationshipLinesCarryColor() throws {
        let nodes = [
            NousNode(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, type: .conversation, title: "Conversation"),
            NousNode(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, type: .note, title: "Note"),
            NousNode(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, type: .conversation, title: "Conversation 2", isFavorite: true)
        ]
        let scene = GalaxyScene()
        scene.size = CGSize(width: 480, height: 320)
        scene.graphNodes = nodes
        scene.positions = [
            nodes[0].id: GraphPosition(x: -40, y: 0),
            nodes[1].id: GraphPosition(x: 0, y: 0),
            nodes[2].id: GraphPosition(x: 40, y: 0)
        ]
        scene.rebuildScene()

        for node in nodes {
            let nodeShape = try XCTUnwrap(scene.children.compactMap { $0 as? SKShapeNode }.first { $0.name == node.id.uuidString })
            assertNeutralNodeFill(nodeShape.fillColor)
        }

        scene.refreshPresentationForTesting(selectedNodeId: nodes[0].id)
        let selectedShape = try XCTUnwrap(scene.children.compactMap { $0 as? SKShapeNode }.first { $0.name == nodes[0].id.uuidString })
        assertNeutralNodeFill(selectedShape.fillColor)
        XCTAssertGreaterThan(selectedShape.strokeColor.redComponent, selectedShape.strokeColor.blueComponent)
    }

    func testCandidateEdgesStaySubtleUntilANodeIsSelected() throws {
        let source = NousNode(type: .conversation, title: "Source")
        let target = NousNode(type: .conversation, title: "Target")
        let edge = NodeEdge(
            sourceId: source.id,
            targetId: target.id,
            strength: 0.92,
            type: .semantic,
            relationKind: .topicSimilarity,
            confidence: 0.92
        )
        let scene = GalaxyScene()
        scene.size = CGSize(width: 480, height: 320)
        scene.graphNodes = [source, target]
        scene.graphEdges = [edge]
        scene.highlightedEdgeIds = [edge.id]
        scene.positions = [
            source.id: GraphPosition(x: -40, y: 0),
            target.id: GraphPosition(x: 40, y: 0)
        ]
        scene.rebuildScene()

        let quietLine = try XCTUnwrap(scene.children.compactMap { $0 as? SKShapeNode }.first { $0.zPosition == -1 })
        XCTAssertLessThanOrEqual(quietLine.strokeColor.alphaComponent, 0.08)
        XCTAssertLessThanOrEqual(quietLine.lineWidth, 0.45)

        scene.refreshPresentationForTesting(selectedNodeId: source.id)

        let focusedLine = try XCTUnwrap(scene.children.compactMap { $0 as? SKShapeNode }.first { $0.zPosition == -1 })
        XCTAssertGreaterThanOrEqual(focusedLine.strokeColor.alphaComponent, 0.50)
        XCTAssertGreaterThanOrEqual(focusedLine.lineWidth, 0.9)
    }

    func testEmptyCanvasIsATapTarget() {
        let node = NousNode(type: .conversation, title: "Quiet node")
        let scene = GalaxyScene()
        scene.size = CGSize(width: 480, height: 320)
        scene.graphNodes = [node]
        scene.positions = [
            node.id: GraphPosition(x: 0, y: 0)
        ]
        scene.rebuildScene()

        XCTAssertEqual(scene.tapTarget(at: CGPoint(x: 140, y: 80)), .canvas)
    }

    func testNodeTitlesRevealOnlyAfterZoomingIn() throws {
        let node = NousNode(type: .conversation, title: "精神健康")
        let scene = GalaxyScene()
        scene.size = CGSize(width: 480, height: 320)
        scene.graphNodes = [node]
        scene.positions = [
            node.id: GraphPosition(x: 0, y: 0)
        ]
        scene.rebuildScene()

        scene.setCameraScaleForTesting(GalaxyZoomPresentation.titleRevealScale + 0.2)
        let zoomedOutLabel = try XCTUnwrap(scene.titleLabelForTesting(nodeId: node.id))
        XCTAssertEqual(zoomedOutLabel.text, "精神健康")
        XCTAssertEqual(zoomedOutLabel.alpha, 0, accuracy: 0.001)

        scene.setCameraScaleForTesting(GalaxyZoomPresentation.titleRevealScale - 0.12)
        let zoomedInLabel = try XCTUnwrap(scene.titleLabelForTesting(nodeId: node.id))
        XCTAssertEqual(zoomedInLabel.alpha, 1, accuracy: 0.001)
    }

    func testRefreshingSelectionDoesNotResetCameraScale() {
        let node = NousNode(type: .conversation, title: "精神健康")
        let scene = GalaxyScene()
        scene.size = CGSize(width: 480, height: 320)
        scene.graphNodes = [node]
        scene.positions = [
            node.id: GraphPosition(x: 0, y: 0)
        ]
        scene.rebuildScene()
        scene.setCameraScaleForTesting(0.48)

        scene.refreshPresentationForTesting(selectedNodeId: node.id)

        XCTAssertEqual(scene.cameraScaleForTesting, 0.48, accuracy: 0.001)
    }

    func testZoomedOutNodesKeepObsidianLikeDragHitArea() {
        let node = NousNode(type: .conversation, title: "精神健康")
        let scene = GalaxyScene()
        scene.size = CGSize(width: 480, height: 320)
        scene.graphNodes = [node]
        scene.positions = [
            node.id: GraphPosition(x: 0, y: 0)
        ]
        scene.rebuildScene()
        scene.setCameraScaleForTesting(1.7)

        XCTAssertEqual(scene.tapTarget(at: CGPoint(x: 32, y: 0)), .node(node.id))
    }

    func testNodeDragPreservesPointerOffset() throws {
        let node = NousNode(type: .conversation, title: "精神健康")
        let scene = GalaxyScene()
        scene.size = CGSize(width: 480, height: 320)
        scene.graphNodes = [node]
        scene.positions = [
            node.id: GraphPosition(x: 40, y: 40)
        ]
        scene.rebuildScene()

        scene.beginPointerInteractionForTesting(at: CGPoint(x: 52, y: 40))
        scene.movePointerInteractionForTesting(to: CGPoint(x: 152, y: 40))

        let movedPosition = try XCTUnwrap(scene.positions[node.id])
        XCTAssertEqual(movedPosition.x, 140, accuracy: 0.001)
        XCTAssertEqual(movedPosition.y, 40, accuracy: 0.001)
    }

    func testCanvasDragPansCameraWithoutMovingNodes() throws {
        let node = NousNode(type: .conversation, title: "精神健康")
        let scene = GalaxyScene()
        scene.size = CGSize(width: 480, height: 320)
        scene.graphNodes = [node]
        scene.positions = [
            node.id: GraphPosition(x: 0, y: 0)
        ]
        scene.rebuildScene()
        let originalPosition = try XCTUnwrap(scene.positions[node.id])

        scene.beginPointerInteractionForTesting(at: CGPoint(x: 160, y: 90))
        scene.movePointerInteractionForTesting(to: CGPoint(x: 110, y: 70))

        let cameraPosition = scene.cameraPositionForTesting
        let currentPosition = try XCTUnwrap(scene.positions[node.id])
        XCTAssertGreaterThan(cameraPosition.x, 0)
        XCTAssertGreaterThan(cameraPosition.y, 0)
        XCTAssertEqual(currentPosition.x, originalPosition.x, accuracy: 0.001)
        XCTAssertEqual(currentPosition.y, originalPosition.y, accuracy: 0.001)
    }

    private func assertNeutralNodeFill(_ color: SKColor, file: StaticString = #filePath, line: UInt = #line) {
        let components = [color.redComponent, color.greenComponent, color.blueComponent]
        let spread = (components.max() ?? 0) - (components.min() ?? 0)
        XCTAssertLessThanOrEqual(spread, 0.045, file: file, line: line)
        XCTAssertGreaterThanOrEqual(components.min() ?? 0, 0.68, file: file, line: line)
    }

    func testCanvasDragKeepsAccumulatingFromStableViewCoordinates() throws {
        let view = SKView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let scene = GalaxyScene(size: CGSize(width: 480, height: 320))
        view.presentScene(scene)
        scene.rebuildScene()
        scene.setCameraScaleForTesting(1)

        scene.mouseDown(with: mouseEvent(type: .leftMouseDown, at: CGPoint(x: 240, y: 160)))
        scene.mouseDragged(with: mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 190, y: 160)))
        let firstCameraPosition = scene.cameraPositionForTesting

        scene.mouseDragged(with: mouseEvent(type: .leftMouseDragged, at: CGPoint(x: 140, y: 160)))
        let secondCameraPosition = scene.cameraPositionForTesting

        XCTAssertEqual(firstCameraPosition.x, 50, accuracy: 0.001)
        XCTAssertEqual(secondCameraPosition.x, 100, accuracy: 0.001)
    }

    func testNodePressDoesNotStartDragPhysicsBeforeMovement() throws {
        let dragged = NousNode(type: .conversation, title: "中心")
        let connected = NousNode(type: .conversation, title: "远端")
        let scene = GalaxyScene()
        scene.size = CGSize(width: 640, height: 420)
        scene.graphNodes = [dragged, connected]
        scene.graphEdges = [
            NodeEdge(sourceId: dragged.id, targetId: connected.id, strength: 1.0, type: .semantic)
        ]
        scene.positions = [
            dragged.id: GraphPosition(x: 0, y: 0),
            connected.id: GraphPosition(x: 320, y: 0)
        ]
        scene.rebuildScene()
        var movedNodeIds: [UUID] = []
        scene.onNodeMoved = { id, _ in
            movedNodeIds.append(id)
        }

        scene.beginPointerInteractionForTesting(at: .zero)
        for frame in 1...10 {
            scene.update(Double(frame) / 60.0)
        }

        let draggedAfterPress = try XCTUnwrap(scene.positions[dragged.id])
        let connectedAfterPress = try XCTUnwrap(scene.positions[connected.id])
        XCTAssertEqual(draggedAfterPress.x, 0, accuracy: 0.001)
        XCTAssertEqual(draggedAfterPress.y, 0, accuracy: 0.001)
        XCTAssertEqual(connectedAfterPress.x, 320, accuracy: 0.001)
        XCTAssertEqual(connectedAfterPress.y, 0, accuracy: 0.001)
        XCTAssertTrue(movedNodeIds.isEmpty)
    }

    func testNodeDragKeepsRelaxingConnectedNodesAcrossFrames() throws {
        let dragged = NousNode(type: .conversation, title: "中心")
        let direct = NousNode(type: .conversation, title: "直接关系")
        let secondDegree = NousNode(type: .conversation, title: "二度关系")
        let remote = NousNode(type: .conversation, title: "另一组")
        let scene = GalaxyScene()
        scene.size = CGSize(width: 640, height: 420)
        scene.graphNodes = [dragged, direct, secondDegree, remote]
        scene.graphEdges = [
            NodeEdge(sourceId: dragged.id, targetId: direct.id, strength: 1.0, type: .semantic),
            NodeEdge(sourceId: direct.id, targetId: secondDegree.id, strength: 0.88, type: .semantic)
        ]
        scene.positions = [
            dragged.id: GraphPosition(x: 0, y: 0),
            direct.id: GraphPosition(x: 90, y: 0),
            secondDegree.id: GraphPosition(x: 180, y: 0),
            remote.id: GraphPosition(x: -180, y: 80)
        ]
        scene.rebuildScene()

        scene.beginPointerInteractionForTesting(at: .zero)
        scene.movePointerInteractionForTesting(to: CGPoint(x: 36, y: 0))

        let directAfterDrag = try XCTUnwrap(scene.positions[direct.id])
        let secondAfterDrag = try XCTUnwrap(scene.positions[secondDegree.id])
        let remoteAfterDrag = try XCTUnwrap(scene.positions[remote.id])

        for frame in 1...10 {
            scene.update(Double(frame) / 60.0)
        }

        let directAfterFrames = try XCTUnwrap(scene.positions[direct.id])
        let secondAfterFrames = try XCTUnwrap(scene.positions[secondDegree.id])
        let remoteAfterFrames = try XCTUnwrap(scene.positions[remote.id])

        XCTAssertGreaterThan(directAfterFrames.x, directAfterDrag.x + 4)
        XCTAssertGreaterThan(secondAfterFrames.x, secondAfterDrag.x + 1)
        XCTAssertEqual(remoteAfterFrames.x, remoteAfterDrag.x, accuracy: 0.001)
        XCTAssertEqual(remoteAfterFrames.y, remoteAfterDrag.y, accuracy: 0.001)
    }

    private func mouseEvent(type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
    }
}
