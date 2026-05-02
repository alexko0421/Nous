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
}
