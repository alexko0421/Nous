import XCTest
@testable import Nous

@MainActor
final class ConstellationDominantUnderFilterTests: XCTestCase {

    var store: NodeStore!
    var vectorStore: VectorStore!
    var constellationService: ConstellationService!
    var graphEngine: GraphEngine!

    override func setUpWithError() throws {
        store = try NodeStore.inMemoryForTesting()
        vectorStore = VectorStore(nodeStore: store)
        constellationService = ConstellationService(nodeStore: store, vectorStore: vectorStore)
        graphEngine = GraphEngine(nodeStore: store, vectorStore: vectorStore)
    }

    override func tearDownWithError() throws {
        graphEngine = nil
        constellationService = nil
        vectorStore = nil
        store = nil
    }

    // MARK: - Helpers

    private func makeVM() -> GalaxyViewModel {
        GalaxyViewModel(
            nodeStore: store,
            graphEngine: graphEngine,
            constellationService: constellationService
        )
    }

    private func seedClaim(
        text: String,
        confidence: Double,
        memberNodeIds: [UUID],
        runId: UUID
    ) throws {
        let m1 = UUID()
        try store.insertMessageForTest(id: m1, nodeId: memberNodeIds[0])
        let m2 = UUID()
        try store.insertMessageForTest(id: m2, nodeId: memberNodeIds[1])

        let rc = ReflectionClaim(
            runId: runId,
            claim: text,
            confidence: confidence,
            whyNonObvious: "x",
            status: .active
        )
        var evidence: [ReflectionEvidence] = [
            ReflectionEvidence(reflectionId: rc.id, messageId: m1),
            ReflectionEvidence(reflectionId: rc.id, messageId: m2),
        ]
        // If there are more than 2 member nodes, add evidence for them too
        for nodeId in memberNodeIds.dropFirst(2) {
            let m = UUID()
            try store.insertMessageForTest(id: m, nodeId: nodeId)
            evidence.append(ReflectionEvidence(reflectionId: rc.id, messageId: m))
        }
        // persistReflectionRun expects only the claims for this call — use a
        // run-per-claim approach so each claim gets its own run row.
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
        try store.persistReflectionRun(run, claims: [rc], evidence: evidence)
    }

    // MARK: - Tests

    func test_dominantIsRecomputedWhenProjectFilterChanges() async throws {
        let projA = UUID()
        let projB = UUID()
        let nFreeChat1 = UUID(); let nFreeChat2 = UUID()
        let nProjA1 = UUID(); let nProjA2 = UUID()
        let nProjB1 = UUID(); let nProjB2 = UUID()

        // Seed projects so FK constraint on nodes.projectId is satisfied
        try store.insertProjectForTest(id: projA, title: "Project A")
        try store.insertProjectForTest(id: projB, title: "Project B")

        // Insert nodes with their respective projectIds
        try store.insertNodeForTest(id: nFreeChat1, projectId: nil)
        try store.insertNodeForTest(id: nFreeChat2, projectId: nil)
        try store.insertNodeForTest(id: nProjA1, projectId: projA)
        try store.insertNodeForTest(id: nProjA2, projectId: projA)
        try store.insertNodeForTest(id: nProjB1, projectId: projB)
        try store.insertNodeForTest(id: nProjB2, projectId: projB)

        // Each claim needs a distinct run (unique per runId in reflection_runs).
        let runFree = UUID()
        let runA = UUID()
        let runB = UUID()

        try seedClaim(text: "free motif", confidence: 0.95, memberNodeIds: [nFreeChat1, nFreeChat2], runId: runFree)
        try seedClaim(text: "projA motif", confidence: 0.7, memberNodeIds: [nProjA1, nProjA2], runId: runA)
        try seedClaim(text: "projB motif", confidence: 0.6, memberNodeIds: [nProjB1, nProjB2], runId: runB)

        let vm = makeVM()
        vm.load()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Whole Galaxy (no filter): dominant is free motif at 0.95
        vm.setProjectFilter(nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        let whole = vm.visibleConstellations
        XCTAssertEqual(whole.count, 3, "all 3 constellations visible when unfiltered")
        XCTAssertEqual(whole.first(where: \.isDominant)?.constellation.label, "free motif",
                       "highest-confidence (0.95) constellation should be dominant in unfiltered view")

        // Filter to projA: only projA's constellation visible, dominant is "projA motif"
        vm.setProjectFilter(projA)
        try await Task.sleep(nanoseconds: 200_000_000)
        let onlyA = vm.visibleConstellations
        XCTAssertEqual(onlyA.count, 1, "only projA constellation visible under projA filter")
        XCTAssertEqual(onlyA[0].constellation.label, "projA motif")
        XCTAssertTrue(onlyA[0].isDominant, "sole visible constellation must be dominant")

        // Filter to projB: projB's constellation is dominant
        vm.setProjectFilter(projB)
        try await Task.sleep(nanoseconds: 200_000_000)
        let onlyB = vm.visibleConstellations
        XCTAssertEqual(onlyB.count, 1, "only projB constellation visible under projB filter")
        XCTAssertEqual(onlyB[0].constellation.label, "projB motif")
        XCTAssertTrue(onlyB[0].isDominant, "sole visible constellation must be dominant")
    }

    func test_constellationHidesIfFilteredVisibleMembersBelowTwo() async throws {
        let projA = UUID()
        let nodeMixed1 = UUID()  // in projA
        let nodeMixed2 = UUID()  // free-chat (nil)

        // Seed project so FK constraint on nodes.projectId is satisfied
        try store.insertProjectForTest(id: projA, title: "Project A")

        try store.insertNodeForTest(id: nodeMixed1, projectId: projA)
        try store.insertNodeForTest(id: nodeMixed2, projectId: nil)

        let runId = UUID()
        try seedClaim(text: "split motif", confidence: 0.9, memberNodeIds: [nodeMixed1, nodeMixed2], runId: runId)

        let vm = makeVM()
        vm.load()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Whole Galaxy: constellation visible (both members present)
        vm.setProjectFilter(nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.visibleConstellations.count, 1,
                       "constellation should be visible when both members are present")

        // Filter to projA: only nodeMixed1 visible → drops below 2 members → hidden
        vm.setProjectFilter(projA)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.visibleConstellations.count, 0,
                       "constellation with only 1 visible member must be hidden")
    }
}
