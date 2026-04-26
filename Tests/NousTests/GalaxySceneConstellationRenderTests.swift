import XCTest
import SpriteKit
@testable import Nous

@MainActor
final class GalaxySceneConstellationRenderTests: XCTestCase {

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

    private func makeConstellation(
        memberCount: Int,
        confidence: Double = 0.9,
        isDominant: Bool = false
    ) -> (Constellation, [UUID: GraphPosition]) {
        let id = UUID()
        var members: [UUID] = []
        var positions: [UUID: GraphPosition] = [:]
        for i in 0..<memberCount {
            let nid = UUID()
            members.append(nid)
            positions[nid] = GraphPosition(x: Float(i * 50), y: Float(i * 50))
        }
        let c = Constellation(
            id: id,
            claimId: id,
            label: "label",
            derivedShortLabel: "label",
            confidence: confidence,
            memberNodeIds: members,
            centroidEmbedding: nil,
            isDominant: isDominant
        )
        return (c, positions)
    }

    private func haloEffectNodeCount(_ scene: GalaxyScene) -> Int {
        scene.children.filter { $0 is SKEffectNode }.count
    }

    func test_dominantOnlyState_rendersOneHaloAtAmbientAlpha() {
        let (c, positions) = makeConstellation(memberCount: 3, confidence: 0.9, isDominant: true)
        let scene = makeScene(constellations: [c], positions: positions, dominantId: c.id)

        XCTAssertEqual(haloEffectNodeCount(scene), 1)
        let effect = scene.children.first(where: { $0 is SKEffectNode }) as? SKEffectNode
        XCTAssertEqual(Double(scene.haloAlpha(for: c.id)), 0.08, accuracy: 0.001)
        XCTAssertEqual(effect?.children.count, 3)  // 3 member sprites
    }

    func test_tapRevealedHaloHasFullAlpha() {
        let (c, positions) = makeConstellation(memberCount: 2)
        let scene = makeScene(constellations: [c], positions: positions, revealed: [c.id])

        XCTAssertEqual(Double(scene.haloAlpha(for: c.id)), 0.55, accuracy: 0.001)
    }

    func test_toggleAllVisibleRendersAllAtToggleAlpha() {
        let (c1, p1) = makeConstellation(memberCount: 2, confidence: 0.9)
        let (c2, p2) = makeConstellation(memberCount: 2, confidence: 0.7)
        let positions = p1.merging(p2) { l, _ in l }
        let scene = makeScene(constellations: [c1, c2], positions: positions, toggleAll: true)

        XCTAssertEqual(haloEffectNodeCount(scene), 2)
        XCTAssertEqual(Double(scene.haloAlpha(for: c1.id)), 0.35, accuracy: 0.001)
        XCTAssertEqual(Double(scene.haloAlpha(for: c2.id)), 0.35, accuracy: 0.001)
    }

    func test_rasterizeIsTrueWhenSimAsleep() {
        let (c, positions) = makeConstellation(memberCount: 2)
        let scene = makeScene(constellations: [c], positions: positions, revealed: [c.id])
        scene.isSimActive = false
        scene.rebuildScene()

        let effect = scene.children.first(where: { $0 is SKEffectNode }) as? SKEffectNode
        XCTAssertEqual(effect?.shouldRasterize, true)
    }

    func test_rasterizeIsFalseWhenSimActive() {
        let (c, positions) = makeConstellation(memberCount: 2)
        var scene = makeScene(constellations: [c], positions: positions, revealed: [c.id])
        scene.isSimActive = true
        scene.rebuildScene()

        let effect = scene.children.first(where: { $0 is SKEffectNode }) as? SKEffectNode
        XCTAssertEqual(effect?.shouldRasterize, false)
    }
}
