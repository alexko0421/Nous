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

    func testOrphanReflectionClaimCleansEvidenceRows() throws {
        let (_, claim) = try seedClaim(status: .active, evidenceCount: 2)

        try store.orphanReflectionClaim(id: claim.id)

        XCTAssertTrue(
            try store.fetchReflectionEvidence(reflectionIds: [claim.id]).isEmpty,
            "orphaned reflection claims should not keep stale evidence rows around"
        )
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
