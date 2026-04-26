import XCTest
import SpriteKit
@testable import Nous

@MainActor
final class OwnershipHandoffTests: XCTestCase {

    func test_simulationOwnsPositions_defaultIsFalse() {
        let scene = GalaxyScene()
        XCTAssertFalse(scene.simulationOwnsPositions)
    }

    func test_whenSimulationDoesNotOwn_externalAssignmentTakesEffect() {
        let scene = GalaxyScene()
        scene.simulationOwnsPositions = false

        let nodeId = UUID()
        let staleVMPositions = [nodeId: GraphPosition(x: 1, y: 1)]

        // Simulate the gated assignment that GalaxySceneContainer.updateNSView
        // performs:
        if !scene.simulationOwnsPositions {
            scene.positions = staleVMPositions
        }

        XCTAssertEqual(scene.positions[nodeId]?.x, 1)
        XCTAssertEqual(scene.positions[nodeId]?.y, 1)
    }

    func test_whenSimulationOwns_externalAssignmentIsBlocked() {
        let scene = GalaxyScene()

        let nodeId = UUID()
        let liveSimPositions = [nodeId: GraphPosition(x: 100, y: 100)]
        scene.positions = liveSimPositions  // sim has placed the node here

        scene.simulationOwnsPositions = true

        // SwiftUI rerender triggers a stale copy attempt
        let staleVMPositions = [nodeId: GraphPosition(x: 0, y: 0)]
        if !scene.simulationOwnsPositions {
            scene.positions = staleVMPositions  // gated; should NOT execute
        }

        // Live sim positions are preserved
        XCTAssertEqual(scene.positions[nodeId]?.x, 100)
        XCTAssertEqual(scene.positions[nodeId]?.y, 100)
    }

    func test_releasingOwnershipReopensExternalAssignment() {
        let scene = GalaxyScene()
        let nodeId = UUID()

        scene.simulationOwnsPositions = true
        scene.positions = [nodeId: GraphPosition(x: 100, y: 100)]

        // Sim sleeps, releases ownership
        scene.simulationOwnsPositions = false

        let newVMPositions = [nodeId: GraphPosition(x: 50, y: 50)]
        if !scene.simulationOwnsPositions {
            scene.positions = newVMPositions
        }

        XCTAssertEqual(scene.positions[nodeId]?.x, 50)
        XCTAssertEqual(scene.positions[nodeId]?.y, 50)
    }
}
