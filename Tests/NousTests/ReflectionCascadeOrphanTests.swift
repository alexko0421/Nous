import XCTest
@testable import Nous

final class ReflectionCascadeOrphanTests: XCTestCase {

    var store: NodeStore!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    // MARK: - Manual orphan

    func testOrphanReflectionClaimFlipsActiveToOrphaned() throws {
        let (_, claim) = try seedClaim(status: .active, evidenceCount: 2)

        try store.orphanReflectionClaim(id: claim.id)

        let remaining = try store.fetchActiveReflectionClaims(projectId: nil)
        XCTAssertFalse(remaining.contains { $0.id == claim.id })
    }

    func testOrphanReflectionClaimIsIdempotentOnAlreadyOrphaned() throws {
        let (_, claim) = try seedClaim(status: .orphaned, evidenceCount: 2)

        try store.orphanReflectionClaim(id: claim.id)
        try store.orphanReflectionClaim(id: claim.id) // must not throw

        let remaining = try store.fetchActiveReflectionClaims(projectId: nil)
        XCTAssertFalse(remaining.contains { $0.id == claim.id })
    }

    // MARK: - Reconcile pass

    func testReconcileFlipsClaimWithOnlyOneEvidence() throws {
        let (_, claim) = try seedClaim(status: .active, evidenceCount: 1)

        let flipped = try store.reconcileOrphanedReflectionClaims()

        XCTAssertEqual(flipped, [claim.id])
        XCTAssertFalse(try store.fetchActiveReflectionClaims(projectId: nil)
            .contains { $0.id == claim.id })
    }

    func testReconcileLeavesHealthyClaimAlone() throws {
        let (_, claim) = try seedClaim(status: .active, evidenceCount: 2)

        let flipped = try store.reconcileOrphanedReflectionClaims()

        XCTAssertTrue(flipped.isEmpty)
        XCTAssertTrue(try store.fetchActiveReflectionClaims(projectId: nil)
            .contains { $0.id == claim.id })
    }

    func testReconcileIgnoresAlreadyOrphanedClaims() throws {
        // Orphaned claim with 0 evidence must not re-appear in flipped set.
        _ = try seedClaim(status: .orphaned, evidenceCount: 0)

        let flipped = try store.reconcileOrphanedReflectionClaims()
        XCTAssertTrue(flipped.isEmpty)
    }

    // MARK: - Cascade via deleteNode

    func testDeleteNodeCascadeOrphansClaimWhenEvidenceFallsBelowTwo() throws {
        // Two evidence rows, one per message node. Delete one node → one
        // message cascades out → one evidence row cascades out → claim has
        // 1 evidence → must flip to orphaned.
        let nodeKeep = NousNode(type: .conversation, title: "keep")
        let nodeDrop = NousNode(type: .conversation, title: "drop")
        try store.insertNode(nodeKeep)
        try store.insertNode(nodeDrop)

        let msgKeep = Message(nodeId: nodeKeep.id, role: .user, content: "a")
        let msgDrop = Message(nodeId: nodeDrop.id, role: .user, content: "b")
        try store.insertMessage(msgKeep)
        try store.insertMessage(msgDrop)

        let run = ReflectionRun(
            projectId: nil,
            weekStart: Date(timeIntervalSince1970: 0),
            weekEnd: Date(timeIntervalSince1970: 100),
            ranAt: Date(timeIntervalSince1970: 100),
            status: .success,
            rejectionReason: nil,
            costCents: 0
        )
        let claim = ReflectionClaim(
            runId: run.id,
            claim: "c",
            confidence: 0.9,
            whyNonObvious: "why",
            status: .active
        )
        let evKeep = ReflectionEvidence(reflectionId: claim.id, messageId: msgKeep.id)
        let evDrop = ReflectionEvidence(reflectionId: claim.id, messageId: msgDrop.id)
        try store.persistReflectionRun(run, claims: [claim], evidence: [evKeep, evDrop])

        // Precondition: claim is active with 2 evidence rows.
        XCTAssertTrue(try store.fetchActiveReflectionClaims(projectId: nil)
            .contains { $0.id == claim.id })

        try store.deleteNode(id: nodeDrop.id)

        XCTAssertFalse(try store.fetchActiveReflectionClaims(projectId: nil)
            .contains { $0.id == claim.id },
                       "claim must orphan after one of its two evidence rows cascades out")
    }

    func testDeleteNodeLeavesClaimActiveWhenAnotherEvidenceKeepsFloor() throws {
        // Three evidence rows; drop one node → 2 evidence left → claim stays active.
        let nA = NousNode(type: .conversation, title: "a")
        let nB = NousNode(type: .conversation, title: "b")
        let nC = NousNode(type: .conversation, title: "c")
        try store.insertNode(nA)
        try store.insertNode(nB)
        try store.insertNode(nC)

        let mA = Message(nodeId: nA.id, role: .user, content: "a")
        let mB = Message(nodeId: nB.id, role: .user, content: "b")
        let mC = Message(nodeId: nC.id, role: .user, content: "c")
        try store.insertMessage(mA)
        try store.insertMessage(mB)
        try store.insertMessage(mC)

        let run = ReflectionRun(
            projectId: nil,
            weekStart: Date(timeIntervalSince1970: 0),
            weekEnd: Date(timeIntervalSince1970: 100),
            ranAt: Date(timeIntervalSince1970: 100),
            status: .success,
            rejectionReason: nil,
            costCents: 0
        )
        let claim = ReflectionClaim(
            runId: run.id,
            claim: "c",
            confidence: 0.9,
            whyNonObvious: "why",
            status: .active
        )
        try store.persistReflectionRun(
            run,
            claims: [claim],
            evidence: [
                ReflectionEvidence(reflectionId: claim.id, messageId: mA.id),
                ReflectionEvidence(reflectionId: claim.id, messageId: mB.id),
                ReflectionEvidence(reflectionId: claim.id, messageId: mC.id)
            ]
        )

        try store.deleteNode(id: nA.id)

        XCTAssertTrue(try store.fetchActiveReflectionClaims(projectId: nil)
            .contains { $0.id == claim.id },
                      "two evidence rows remain — claim must still be active")
    }

    // MARK: - Distinct-nodeId reconcile rule

    func test_orphansClaimWhenEvidenceCollapsesToSingleConversation() throws {
        // Setup: a claim with 3 evidence messages spanning 2 conversations.
        // Surgically remove the nodeB evidence row via raw SQL (bypassing
        // deleteNode's built-in auto-reconcile) so that reconcile() itself
        // is the thing under test here.
        // After removal, evidence collapses to 2 messages all in nodeA
        // → COUNT(DISTINCT m.nodeId) = 1 < 2 → reconcile must flip the claim.
        let nodeA = NousNode(type: .conversation, title: "nodeA")
        let nodeB = NousNode(type: .conversation, title: "nodeB")
        try store.insertNode(nodeA)
        try store.insertNode(nodeB)

        let mA1 = Message(nodeId: nodeA.id, role: .user, content: "a1")
        let mA2 = Message(nodeId: nodeA.id, role: .user, content: "a2")
        let mB1 = Message(nodeId: nodeB.id, role: .user, content: "b1")
        try store.insertMessage(mA1)
        try store.insertMessage(mA2)
        try store.insertMessage(mB1)

        let run = ReflectionRun(
            projectId: nil,
            weekStart: Date(timeIntervalSince1970: 0),
            weekEnd: Date(timeIntervalSince1970: 100),
            ranAt: Date(timeIntervalSince1970: 100),
            status: .success,
            rejectionReason: nil,
            costCents: 0
        )
        let claim = ReflectionClaim(
            runId: run.id,
            claim: "distinct-node collapse",
            confidence: 0.9,
            whyNonObvious: "why",
            status: .active
        )
        try store.persistReflectionRun(
            run,
            claims: [claim],
            evidence: [
                ReflectionEvidence(reflectionId: claim.id, messageId: mA1.id),
                ReflectionEvidence(reflectionId: claim.id, messageId: mA2.id),
                ReflectionEvidence(reflectionId: claim.id, messageId: mB1.id)
            ]
        )

        // Precondition: claim is active spanning 2 nodeIds.
        XCTAssertTrue(try store.fetchActiveReflectionClaims(projectId: nil)
            .contains { $0.id == claim.id })

        // Surgically delete only the evidence row for mB1 — simulates what
        // a CASCADE from a deleted message leaves behind, without invoking
        // deleteNode() which would auto-reconcile before we get to test it.
        try store.executeRawForTest("""
            DELETE FROM reflection_evidence WHERE message_id = '\(mB1.id.uuidString)';
        """)

        // Now only nodeA evidence remains (2 messages, 1 nodeId).
        let flipped = try store.reconcileOrphanedReflectionClaims()
        XCTAssertEqual(flipped, [claim.id],
                       "claim must orphan: evidence collapsed to single conversation")
        XCTAssertFalse(try store.fetchActiveReflectionClaims(projectId: nil)
            .contains { $0.id == claim.id })
    }

    func test_keepsClaimActiveWhenEvidenceStillSpansTwoConversations() throws {
        // Setup: a claim with 3 evidence rows spanning 3 nodes (nA, nA2, nB).
        // Surgically remove the nA2 evidence row (same approach as the orphan
        // test — raw SQL to avoid deleteNode's built-in auto-reconcile).
        // Remaining evidence: nA + nB → still 2 distinct nodeIds → stays active.
        let nA = NousNode(type: .conversation, title: "nA")
        let nA2 = NousNode(type: .conversation, title: "nA2")
        let nB = NousNode(type: .conversation, title: "nB")
        try store.insertNode(nA)
        try store.insertNode(nA2)
        try store.insertNode(nB)

        let mA = Message(nodeId: nA.id, role: .user, content: "a")
        let mA2 = Message(nodeId: nA2.id, role: .user, content: "a2")
        let mB = Message(nodeId: nB.id, role: .user, content: "b")
        try store.insertMessage(mA)
        try store.insertMessage(mA2)
        try store.insertMessage(mB)

        let run = ReflectionRun(
            projectId: nil,
            weekStart: Date(timeIntervalSince1970: 0),
            weekEnd: Date(timeIntervalSince1970: 100),
            ranAt: Date(timeIntervalSince1970: 100),
            status: .success,
            rejectionReason: nil,
            costCents: 0
        )
        let claim = ReflectionClaim(
            runId: run.id,
            claim: "stays active",
            confidence: 0.9,
            whyNonObvious: "why",
            status: .active
        )
        try store.persistReflectionRun(
            run,
            claims: [claim],
            evidence: [
                ReflectionEvidence(reflectionId: claim.id, messageId: mA.id),
                ReflectionEvidence(reflectionId: claim.id, messageId: mA2.id),
                ReflectionEvidence(reflectionId: claim.id, messageId: mB.id)
            ]
        )

        // Remove nA2 evidence — mA (nA) + mB (nB) remain → 2 distinct nodeIds.
        try store.executeRawForTest("""
            DELETE FROM reflection_evidence WHERE message_id = '\(mA2.id.uuidString)';
        """)

        let flipped = try store.reconcileOrphanedReflectionClaims()
        XCTAssertTrue(flipped.isEmpty,
                      "claim must stay active: evidence still spans nA and nB")
        XCTAssertTrue(try store.fetchActiveReflectionClaims(projectId: nil)
            .contains { $0.id == claim.id })
    }

    // MARK: - Helpers

    @discardableResult
    private func seedClaim(
        status: ReflectionClaimStatus,
        evidenceCount: Int
    ) throws -> (run: ReflectionRun, claim: ReflectionClaim) {
        var messages: [Message] = []
        for i in 0..<evidenceCount {
            let node = NousNode(type: .conversation, title: "n\(i)")
            try store.insertNode(node)
            let msg = Message(nodeId: node.id, role: .user, content: "m\(i)")
            try store.insertMessage(msg)
            messages.append(msg)
        }

        let run = ReflectionRun(
            projectId: nil,
            weekStart: Date(timeIntervalSince1970: 0),
            weekEnd: Date(timeIntervalSince1970: 100),
            ranAt: Date(timeIntervalSince1970: 100),
            status: .success,
            rejectionReason: nil,
            costCents: 0
        )
        let claim = ReflectionClaim(
            runId: run.id,
            claim: "seed",
            confidence: 0.8,
            whyNonObvious: "why",
            status: status
        )
        let evidence = messages.map {
            ReflectionEvidence(reflectionId: claim.id, messageId: $0.id)
        }
        try store.persistReflectionRun(run, claims: [claim], evidence: evidence)
        return (run, claim)
    }
}
