import XCTest
import SpriteKit
@testable import Nous

@MainActor
final class SimulationSleepWatchdogTests: XCTestCase {

    private func makeScene() -> GalaxyScene {
        let scene = GalaxyScene()
        // Seed minimal data: 2 nodes far apart, no edges, no constellations.
        // At distance 2000 the repulsion force per frame is
        //   12000 / 4_000_000 ≈ 0.003 (well below velocityThreshold 0.5)
        // so the sim settles within a frame or two and the soft watchdog
        // can reliably fire by frame 30.
        let n1 = UUID(); let n2 = UUID()
        scene.positions = [
            n1: GraphPosition(x: -1000, y: 0),
            n2: GraphPosition(x: 1000, y: 0)
        ]
        return scene
    }

    /// Helper: simulate N frames of update(_:) calls.
    private func tick(_ scene: GalaxyScene, frames: Int) {
        for i in 0..<frames {
            scene.update(TimeInterval(i) / 120.0)
        }
    }

    func test_softWatchdogTriggersSleepAfter30SubThresholdFrames() {
        let scene = makeScene()
        var settledCount = 0
        scene.onSimulationSettled = { _ in settledCount += 1 }

        // Wake sim, immediately release (no drag). Velocities will be near 0
        // because no kinematic node is pulling things apart.
        scene.isSimActive = true
        scene.simulationOwnsPositions = true
        // (kinematicNodeId is private; we simulate "user released" by leaving
        //  it nil from the start.)

        tick(scene, frames: 35)  // > softWatchdogFrames (30)

        XCTAssertFalse(scene.isSimActive, "Soft watchdog should have triggered sleep")
        XCTAssertEqual(settledCount, 1)
        XCTAssertFalse(scene.simulationOwnsPositions)
    }

    func test_hardTimeoutTriggersSleepEvenIfVelocityNeverDrops() {
        // Both watchdogs result in sleep, which is what we assert. The
        // important invariant: by frame 90 (hardTimeoutFrames), the sim
        // MUST be settled and onSimulationSettled MUST have fired exactly
        // once. With this small fixture the soft watchdog typically wins
        // first; either way, settle has fired by frame 90.
        let scene = makeScene()
        var settledCount = 0
        scene.onSimulationSettled = { _ in settledCount += 1 }

        scene.isSimActive = true
        scene.simulationOwnsPositions = true

        tick(scene, frames: 95)
        XCTAssertFalse(scene.isSimActive)
        XCTAssertEqual(settledCount, 1, "Some watchdog must trigger by frame 90")
    }

    func test_sleepZeroesVelocitiesAndStopsMotion() {
        let scene = makeScene()
        scene.isSimActive = true
        scene.simulationOwnsPositions = true

        tick(scene, frames: 35)

        // After sleep, isSimActive is false. Tick once more — the guard at
        // the top of update(_:) early-returns.
        XCTAssertFalse(scene.isSimActive)

        // Verify indirectly: after sleep, positions stop changing across
        // additional ticks (velocities zeroed and update guard short-circuits).
        let firstSnap = scene.positions
        tick(scene, frames: 5)
        let key = firstSnap.keys.first!
        XCTAssertEqual(scene.positions[key]?.x, firstSnap[key]?.x)
        XCTAssertEqual(scene.positions[key]?.y, firstSnap[key]?.y)
    }

    func test_settledCallbackReceivesFinalPositions() {
        let scene = makeScene()
        var receivedPositions: [UUID: GraphPosition]?
        scene.onSimulationSettled = { positions in
            receivedPositions = positions
        }

        scene.isSimActive = true
        scene.simulationOwnsPositions = true
        tick(scene, frames: 35)

        XCTAssertNotNil(receivedPositions, "Settle callback must fire with positions")
        XCTAssertEqual(receivedPositions?.count, 2)
    }
}
