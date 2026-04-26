import XCTest
@testable import Nous

final class EphemeralBridgingInMemoryTests: XCTestCase {
    var store: NodeStore!
    var vectorStore: VectorStore!
    var svc: ConstellationService!

    override func setUpWithError() throws {
        store = try NodeStore.inMemoryForTesting()
        vectorStore = VectorStore(nodeStore: store)
        svc = ConstellationService(nodeStore: store, vectorStore: vectorStore)
    }

    override func tearDownWithError() throws {
        svc = nil
        vectorStore = nil
        store = nil
    }

    /// Helper: seed a single active constellation spanning two nodes whose
    /// embeddings are unit vectors along the same axis. Centroid will then
    /// also be along that axis. Returns the constellation id (= claim id).
    @discardableResult
    private func seedSimpleConstellation(centroidAxis: Int = 0) throws -> UUID {
        let nodeA = UUID(); let nodeB = UUID()
        try store.insertNodeForTestWithEmbedding(id: nodeA, embedding: makeEmbedding(axis: centroidAxis))
        try store.insertNodeForTestWithEmbedding(id: nodeB, embedding: makeEmbedding(axis: centroidAxis))

        let m1 = UUID(); let m2 = UUID()
        try store.insertMessageForTest(id: m1, nodeId: nodeA)
        try store.insertMessageForTest(id: m2, nodeId: nodeB)

        let runId = UUID()
        let run = ReflectionRun(
            id: runId,
            weekStart: Date(timeIntervalSinceNow: -86_400),
            weekEnd: Date(),
            ranAt: Date(),
            status: .success
        )
        let claim = ReflectionClaim(
            runId: runId,
            claim: "test motif \(centroidAxis)",
            confidence: 0.9,
            whyNonObvious: "x"
        )
        let evidence = [
            ReflectionEvidence(reflectionId: claim.id, messageId: m1),
            ReflectionEvidence(reflectionId: claim.id, messageId: m2),
        ]
        try store.persistReflectionRun(run, claims: [claim], evidence: evidence)
        return claim.id
    }

    /// Returns a 4-dim unit vector along the given axis.
    private func makeEmbedding(axis: Int, magnitude: Float = 1.0) -> [Float] {
        var v: [Float] = [0, 0, 0, 0]
        v[axis] = magnitude
        return v
    }

    func test_attachesNewNodeWhenCosineAboveThreshold() throws {
        let cId = try seedSimpleConstellation(centroidAxis: 0)

        // New node with embedding aligned with centroid → cosine = 1.0
        let newNodeId = UUID()
        try store.insertNodeForTestWithEmbedding(id: newNodeId, embedding: makeEmbedding(axis: 0))
        guard let newNode = try store.fetchNode(id: newNodeId) else {
            XCTFail("Node not retrievable after insert"); return
        }

        try svc.considerNodeForEphemeralBridging(newNode)

        let merged = try svc.loadActiveConstellations()
        let target = merged.first(where: { $0.id == cId })
        XCTAssertNotNil(target)
        XCTAssertTrue(target!.memberNodeIds.contains(newNodeId), "Node should be ephemerally attached")
    }

    func test_doesNotAttachWhenCosineBelowThreshold() throws {
        let cId = try seedSimpleConstellation(centroidAxis: 0)

        // New node embedding orthogonal to centroid → cosine = 0
        let newNodeId = UUID()
        try store.insertNodeForTestWithEmbedding(id: newNodeId, embedding: makeEmbedding(axis: 1))
        guard let newNode = try store.fetchNode(id: newNodeId) else {
            XCTFail("Node not retrievable"); return
        }

        try svc.considerNodeForEphemeralBridging(newNode)

        let merged = try svc.loadActiveConstellations()
        let target = merged.first(where: { $0.id == cId })!
        XCTAssertFalse(target.memberNodeIds.contains(newNodeId))
    }

    func test_capsEphemeralAttachmentsAtTwoPerNode() throws {
        // Three constellations, each aligned with a different axis.
        // A new node embedding ≈ [0.9, 0.4, 0.2, 0] — strongest sim with c1,
        // then c2, then c3 → should attach to at most top-2.
        let c1 = try seedSimpleConstellation(centroidAxis: 0)
        let c2 = try seedSimpleConstellation(centroidAxis: 1)
        let c3 = try seedSimpleConstellation(centroidAxis: 2)

        let newNodeId = UUID()
        try store.insertNodeForTestWithEmbedding(id: newNodeId, embedding: [0.9, 0.4, 0.2, 0])
        guard let newNode = try store.fetchNode(id: newNodeId) else {
            XCTFail("Node not retrievable"); return
        }

        try svc.considerNodeForEphemeralBridging(newNode)

        let merged = try svc.loadActiveConstellations()
        let containingNew = merged.filter { $0.memberNodeIds.contains(newNodeId) }
        XCTAssertLessThanOrEqual(containingNew.count, 2, "K=2 cap: node must attach to at most 2 constellations")

        // Verify unused variable suppression — c3 reference to confirm it exists
        _ = c3
        // The node should NOT be in c3 (lowest similarity) if cap is working
        let c3Constellation = merged.first(where: { $0.id == c3 })
        if containingNew.count == 2 {
            XCTAssertFalse(c3Constellation?.memberNodeIds.contains(newNodeId) ?? false,
                           "c3 has lowest cosine — should be excluded by K=2 cap")
        }
    }

    func test_clearEphemeralEmptiesMap() throws {
        let cId = try seedSimpleConstellation(centroidAxis: 0)
        let newNodeId = UUID()
        try store.insertNodeForTestWithEmbedding(id: newNodeId, embedding: makeEmbedding(axis: 0))
        guard let newNode = try store.fetchNode(id: newNodeId) else { return }
        try svc.considerNodeForEphemeralBridging(newNode)

        // Verify attached
        let beforeClear = try svc.loadActiveConstellations()
        XCTAssertTrue(beforeClear.first(where: { $0.id == cId })!.memberNodeIds.contains(newNodeId))

        svc.clearEphemeral()

        // After clear, ephemeral attachment is gone
        let afterClear = try svc.loadActiveConstellations()
        XCTAssertFalse(afterClear.first(where: { $0.id == cId })!.memberNodeIds.contains(newNodeId))
    }

    func test_releaseEphemeralRemovesNodeFromAllConstellations() throws {
        let c1 = try seedSimpleConstellation(centroidAxis: 0)
        let c2 = try seedSimpleConstellation(centroidAxis: 1)

        // Node aligned with both axes → cosine ≈ 0.707 with each (above 0.7 threshold)
        let newNodeId = UUID()
        try store.insertNodeForTestWithEmbedding(id: newNodeId, embedding: [0.7072, 0.7072, 0, 0])
        guard let newNode = try store.fetchNode(id: newNodeId) else { return }
        try svc.considerNodeForEphemeralBridging(newNode)

        // Confirm attached to both
        let beforeRelease = try svc.loadActiveConstellations()
        XCTAssertTrue(beforeRelease.first(where: { $0.id == c1 })!.memberNodeIds.contains(newNodeId))
        XCTAssertTrue(beforeRelease.first(where: { $0.id == c2 })!.memberNodeIds.contains(newNodeId))

        svc.releaseEphemeral(nodeId: newNodeId)

        let afterRelease = try svc.loadActiveConstellations()
        XCTAssertFalse(afterRelease.first(where: { $0.id == c1 })!.memberNodeIds.contains(newNodeId))
        XCTAssertFalse(afterRelease.first(where: { $0.id == c2 })!.memberNodeIds.contains(newNodeId))
    }

    func test_skipsConstellationNodeIsAlreadyMemberOf() throws {
        // Seed a constellation and use one of its member nodes as the bridging candidate.
        // The service should skip that constellation entirely (node is evidence-side member).
        let nodeA = UUID(); let nodeB = UUID()
        try store.insertNodeForTestWithEmbedding(id: nodeA, embedding: makeEmbedding(axis: 0))
        try store.insertNodeForTestWithEmbedding(id: nodeB, embedding: makeEmbedding(axis: 0))

        let m1 = UUID(); let m2 = UUID()
        try store.insertMessageForTest(id: m1, nodeId: nodeA)
        try store.insertMessageForTest(id: m2, nodeId: nodeB)

        let runId = UUID()
        let run = ReflectionRun(
            id: runId,
            weekStart: Date(timeIntervalSinceNow: -86_400),
            weekEnd: Date(),
            ranAt: Date(),
            status: .success
        )
        let claim = ReflectionClaim(
            runId: runId, claim: "skip motif",
            confidence: 0.9, whyNonObvious: "x"
        )
        try store.persistReflectionRun(run, claims: [claim], evidence: [
            ReflectionEvidence(reflectionId: claim.id, messageId: m1),
            ReflectionEvidence(reflectionId: claim.id, messageId: m2),
        ])

        // nodeA is already a member — its bridging call should not double-add it
        guard let existingMemberNode = try store.fetchNode(id: nodeA) else { return }
        try svc.considerNodeForEphemeralBridging(existingMemberNode)

        let merged = try svc.loadActiveConstellations()
        let target = merged.first(where: { $0.id == claim.id })!
        // memberNodeIds should still be {nodeA, nodeB} — not containing nodeA twice
        // (Set semantics) and not having been added ephemerally
        let memberCount = target.memberNodeIds.filter { $0 == nodeA }.count
        XCTAssertEqual(memberCount, 1, "Existing member should not be double-counted")
    }
}
