import XCTest
import SpriteKit
@testable import Nous

@MainActor
final class HaloPriorityCapTests: XCTestCase {

    private func makeConstellations(_ confidences: [Double]) -> ([Constellation], [UUID: GraphPosition]) {
        var consts: [Constellation] = []
        var positions: [UUID: GraphPosition] = [:]
        for (i, conf) in confidences.enumerated() {
            let cid = UUID()
            let n1 = UUID(); let n2 = UUID()
            positions[n1] = GraphPosition(x: Float(i * 100), y: 0)
            positions[n2] = GraphPosition(x: Float(i * 100 + 50), y: 0)
            consts.append(Constellation(
                id: cid, claimId: cid, label: "c\(i)",
                derivedShortLabel: "c\(i)",
                confidence: conf,
                memberNodeIds: [n1, n2],
                centroidEmbedding: nil,
                isDominant: false
            ))
        }
        return (consts, positions)
    }

    private func makeScene(
        constellations: [Constellation],
        positions: [UUID: GraphPosition],
        dominantId: UUID? = nil,
        revealed: Set<UUID> = [],
        toggleAll: Bool = false
    ) -> GalaxyScene {
        let scene = GalaxyScene()
        scene.positions = positions
        scene.constellations = constellations
        scene.dominantConstellationId = dominantId
        scene.revealedConstellationIds = revealed
        scene.toggleAllVisible = toggleAll
        scene.rebuildScene()
        return scene
    }

    private func haloCount(_ scene: GalaxyScene) -> Int {
        scene.children.filter { $0 is SKEffectNode }.count
    }

    func test_capLimitsToggleVisibleHalosToMaxVisible() {
        // 12 constellations in toggle mode → only 8 should render
        let (consts, positions) = makeConstellations(Array(repeating: 0.9, count: 12))
        let scene = makeScene(constellations: consts, positions: positions, toggleAll: true)
        XCTAssertEqual(haloCount(scene), 8)
    }

    func test_tapRevealedRendersEvenBeyondCap() {
        // 12 constellations + tap on 2 of them in toggle mode.
        // Tap-revealed always renders (no cap); dominant absent;
        // toggle fills remainder up to 8 total.
        let (consts, positions) = makeConstellations(Array(repeating: 0.9, count: 12))
        let tapIds: Set<UUID> = [consts[10].id, consts[11].id]
        let scene = makeScene(constellations: consts, positions: positions, revealed: tapIds, toggleAll: true)
        XCTAssertEqual(haloCount(scene), 8)
        // Verify the tap-revealed are among the rendered set
        let rendered = scene.children.compactMap { $0 as? SKEffectNode }
        XCTAssertEqual(rendered.count, 8)
        // (Identity check would require exposing constellation→effect mapping;
        // confirming count + tap presence via alpha tier is sufficient — at
        // least 2 halos should be at 0.55, the rest at 0.35.)
        let tapAlphaCount = rendered.filter { abs(Double($0.alpha) - 0.55) < 0.001 }.count
        XCTAssertEqual(tapAlphaCount, 2)
    }

    func test_dominantAndTapBothRenderUnderCap() {
        let (consts, positions) = makeConstellations(Array(repeating: 0.9, count: 12))
        let dominantId = consts[0].id
        let tapId = consts[1].id
        let scene = makeScene(
            constellations: consts, positions: positions,
            dominantId: dominantId, revealed: [tapId], toggleAll: true
        )
        XCTAssertEqual(haloCount(scene), 8)
        let rendered = scene.children.compactMap { $0 as? SKEffectNode }
        // tap (1 at 0.55) + dominant (1 at 0.08) + toggle (6 at 0.35) = 8
        let tapAlphaCount = rendered.filter { abs(Double($0.alpha) - 0.55) < 0.001 }.count
        let dominantAlphaCount = rendered.filter { abs(Double($0.alpha) - 0.08) < 0.001 }.count
        let toggleAlphaCount = rendered.filter { abs(Double($0.alpha) - 0.35) < 0.001 }.count
        XCTAssertEqual(tapAlphaCount, 1)
        XCTAssertEqual(dominantAlphaCount, 1)
        XCTAssertEqual(toggleAlphaCount, 6)
    }
}
