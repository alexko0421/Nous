import XCTest
@testable import Nous

/// Exercises `ConstellationService.loadActiveConstellations()` end-to-end:
/// active-claim filter, distinct-node floor, K=2 per-node cap with second
/// prune, dominant selection scoped to the latest run, and the 14-day
/// freshness guard. Pairs with the unit-level `ConstellationServiceSkeletonTests`.
final class ConstellationDerivationTests: XCTestCase {
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

    // MARK: - Basic derivation

    func test_emitsConstellationFromActiveClaimSpanningTwoNodes() throws {
        let nodeA = UUID(); let nodeB = UUID()
        try store.insertNodeForTest(id: nodeA)
        try store.insertNodeForTest(id: nodeB)
        let m1 = UUID(); let m2 = UUID()
        try store.insertMessageForTest(id: m1, nodeId: nodeA)
        try store.insertMessageForTest(id: m2, nodeId: nodeB)

        let runId = UUID()
        let run = ReflectionRun(
            id: runId,
            projectId: nil,
            weekStart: Date(timeIntervalSinceNow: -86_400),
            weekEnd: Date(),
            ranAt: Date(),
            status: .success,
            rejectionReason: nil,
            costCents: 0
        )
        let claim = ReflectionClaim(
            runId: runId,
            claim: "Across launches: 「驚被睇穿不夠好」",
            confidence: 0.9,
            whyNonObvious: "x",
            status: .active
        )
        let evidence = [
            ReflectionEvidence(reflectionId: claim.id, messageId: m1),
            ReflectionEvidence(reflectionId: claim.id, messageId: m2),
        ]
        try store.persistReflectionRun(run, claims: [claim], evidence: evidence)

        let result = try svc.loadActiveConstellations()
        XCTAssertEqual(result.count, 1)
        let c = result[0]
        XCTAssertEqual(Set(c.memberNodeIds), Set([nodeA, nodeB]))
        XCTAssertEqual(c.label, "Across launches: 「驚被睇穿不夠好」")
        XCTAssertEqual(c.derivedShortLabel, "驚被睇穿不夠好")
        XCTAssertTrue(c.isDominant)
    }

    func test_dropsClaimWithEvidenceCollapsingToSingleNode() throws {
        // Both messages live in the same conversation node — distinct
        // nodeId count = 1, so derivation must skip this claim entirely.
        let nodeA = UUID()
        try store.insertNodeForTest(id: nodeA)
        let m1 = UUID(); let m2 = UUID()
        try store.insertMessageForTest(id: m1, nodeId: nodeA)
        try store.insertMessageForTest(id: m2, nodeId: nodeA)

        let runId = UUID()
        let run = ReflectionRun(
            id: runId,
            projectId: nil,
            weekStart: Date(timeIntervalSinceNow: -86_400),
            weekEnd: Date(),
            ranAt: Date(),
            status: .success,
            rejectionReason: nil,
            costCents: 0
        )
        let claim = ReflectionClaim(
            runId: runId,
            claim: "single conv",
            confidence: 0.9,
            whyNonObvious: "x",
            status: .active
        )
        let evidence = [
            ReflectionEvidence(reflectionId: claim.id, messageId: m1),
            ReflectionEvidence(reflectionId: claim.id, messageId: m2),
        ]
        try store.persistReflectionRun(run, claims: [claim], evidence: evidence)

        let result = try svc.loadActiveConstellations()
        XCTAssertEqual(result.count, 0)
    }

    // MARK: - K=2 cap + second prune

    func test_appliesKEquals2CapAndSecondPrune() throws {
        // 4 nodes; 3 claims of decreasing confidence:
        //   A: {n1,n2,n3,n4} 0.9
        //   B: {n1,n2}       0.7
        //   C: {n1,n2}       0.5
        // After cap: n1 and n2 hit K=2 in {A,B}. C loses both → empty → second
        // prune drops C.
        let n1 = UUID(); let n2 = UUID(); let n3 = UUID(); let n4 = UUID()
        for n in [n1, n2, n3, n4] { try store.insertNodeForTest(id: n) }

        let runId = UUID()
        let run = ReflectionRun(
            id: runId,
            projectId: nil,
            weekStart: Date(timeIntervalSinceNow: -86_400),
            weekEnd: Date(),
            ranAt: Date(),
            status: .success,
            rejectionReason: nil,
            costCents: 0
        )

        let cA = ReflectionClaim(runId: runId, claim: "A motif",
                                 confidence: 0.9, whyNonObvious: "x",
                                 status: .active)
        let cB = ReflectionClaim(runId: runId, claim: "B motif",
                                 confidence: 0.7, whyNonObvious: "x",
                                 status: .active)
        let cC = ReflectionClaim(runId: runId, claim: "C motif",
                                 confidence: 0.5, whyNonObvious: "x",
                                 status: .active)

        var evidence: [ReflectionEvidence] = []
        for n in [n1, n2, n3, n4] {
            let m = UUID()
            try store.insertMessageForTest(id: m, nodeId: n)
            evidence.append(ReflectionEvidence(reflectionId: cA.id, messageId: m))
        }
        for n in [n1, n2] {
            let mB = UUID()
            try store.insertMessageForTest(id: mB, nodeId: n)
            evidence.append(ReflectionEvidence(reflectionId: cB.id, messageId: mB))
            let mC = UUID()
            try store.insertMessageForTest(id: mC, nodeId: n)
            evidence.append(ReflectionEvidence(reflectionId: cC.id, messageId: mC))
        }
        try store.persistReflectionRun(run, claims: [cA, cB, cC], evidence: evidence)

        let result = try svc.loadActiveConstellations()
        let labels = Set(result.map { $0.label })
        XCTAssertEqual(labels, Set(["A motif", "B motif"]))

        // Each surviving constellation must still have ≥2 members.
        for c in result {
            XCTAssertGreaterThanOrEqual(c.memberNodeIds.count, 2)
        }
    }

    // MARK: - Dominant selection

    func test_dominantPicksHighestConfidenceFromLatestRun() throws {
        let nA = UUID(); let nB = UUID()
        try store.insertNodeForTest(id: nA)
        try store.insertNodeForTest(id: nB)

        let oldRun = UUID()
        let newRun = UUID()
        let oldRunObj = ReflectionRun(
            id: oldRun, projectId: nil,
            weekStart: Date(timeIntervalSinceNow: -86_400 * 35),
            weekEnd: Date(timeIntervalSinceNow: -86_400 * 28),
            ranAt: Date(timeIntervalSinceNow: -86_400 * 30),
            status: .success, rejectionReason: nil, costCents: 0
        )
        let newRunObj = ReflectionRun(
            id: newRun, projectId: nil,
            weekStart: Date(timeIntervalSinceNow: -86_400 * 7),
            weekEnd: Date(),
            ranAt: Date(),
            status: .success, rejectionReason: nil, costCents: 0
        )

        // Older claim has highest confidence overall, but should NOT be
        // dominant — dominant is scoped to the latest run.
        let oldHigh = ReflectionClaim(runId: oldRun, claim: "old high",
                                      confidence: 0.95, whyNonObvious: "x",
                                      status: .active)
        let newMid = ReflectionClaim(runId: newRun, claim: "new mid",
                                     confidence: 0.7, whyNonObvious: "x",
                                     status: .active)
        let newHigh = ReflectionClaim(runId: newRun, claim: "new high",
                                      confidence: 0.85, whyNonObvious: "x",
                                      status: .active)

        var evidence: [ReflectionEvidence] = []
        for c in [oldHigh, newMid, newHigh] {
            for n in [nA, nB] {
                let m = UUID()
                try store.insertMessageForTest(id: m, nodeId: n)
                evidence.append(ReflectionEvidence(reflectionId: c.id, messageId: m))
            }
        }
        try store.persistReflectionRun(
            oldRunObj,
            claims: [oldHigh],
            evidence: evidence.filter { $0.reflectionId == oldHigh.id }
        )
        try store.persistReflectionRun(
            newRunObj,
            claims: [newMid, newHigh],
            evidence: evidence.filter { $0.reflectionId != oldHigh.id }
        )

        let result = try svc.loadActiveConstellations()
        let dominant = result.first(where: { $0.isDominant })
        XCTAssertEqual(dominant?.label, "new high",
                       "dominant must be highest-confidence claim from the latest run")

        // Old run must have non-dominant survivor (still active, just not dominant).
        XCTAssertTrue(result.contains(where: { $0.label == "old high" && !$0.isDominant }))
    }

    func test_freshnessGuardSuppressesDominantIfLatestRunOlderThan14Days() throws {
        let nA = UUID(); let nB = UUID()
        try store.insertNodeForTest(id: nA)
        try store.insertNodeForTest(id: nB)

        let staleRun = UUID()
        let staleRunObj = ReflectionRun(
            id: staleRun, projectId: nil,
            weekStart: Date(timeIntervalSinceNow: -86_400 * 25),
            weekEnd: Date(timeIntervalSinceNow: -86_400 * 18),
            ranAt: Date(timeIntervalSinceNow: -86_400 * 20),
            status: .success, rejectionReason: nil, costCents: 0
        )
        let stale = ReflectionClaim(runId: staleRun, claim: "stale",
                                    confidence: 0.95, whyNonObvious: "x",
                                    status: .active)

        var evidence: [ReflectionEvidence] = []
        for n in [nA, nB] {
            let m = UUID()
            try store.insertMessageForTest(id: m, nodeId: n)
            evidence.append(ReflectionEvidence(reflectionId: stale.id, messageId: m))
        }
        try store.persistReflectionRun(staleRunObj, claims: [stale], evidence: evidence)

        let result = try svc.loadActiveConstellations()
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isDominant,
                       "freshness guard must suppress dominant when latest run >14 days old")
    }
}
