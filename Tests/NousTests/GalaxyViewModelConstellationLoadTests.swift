import XCTest
@testable import Nous

@MainActor
final class GalaxyViewModelConstellationLoadTests: XCTestCase {
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

    private func seedActiveClaim(claim: String = "test claim", confidence: Double = 0.9) throws {
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
        let rc = ReflectionClaim(
            runId: runId,
            claim: claim,
            confidence: confidence,
            whyNonObvious: "x",
            status: .active
        )
        let evidence = [
            ReflectionEvidence(reflectionId: rc.id, messageId: m1),
            ReflectionEvidence(reflectionId: rc.id, messageId: m2),
        ]
        try store.persistReflectionRun(run, claims: [rc], evidence: evidence)
    }

    // MARK: - Tests

    func test_loadPopulatesConstellationsFromService() async throws {
        try seedActiveClaim(claim: "test claim", confidence: 0.9)

        let vm = makeVM()
        XCTAssertEqual(vm.constellations.count, 0, "constellations start empty before load")

        vm.load()
        // Allow the async Task inside load() to settle
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(vm.constellations.count, 1)
        XCTAssertEqual(vm.constellations[0].label, "test claim")
        XCTAssertNotNil(vm.dominantConstellationId)
        XCTAssertEqual(vm.dominantConstellationId, vm.constellations[0].id)
    }

    func test_loadWithEmptyStoreYieldsEmptyConstellations() async throws {
        let vm = makeVM()
        vm.load()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(vm.constellations.count, 0)
        XCTAssertNil(vm.dominantConstellationId)
    }

    func test_reflectionCompletedNotificationTriggersRefresh() async throws {
        let vm = makeVM()
        vm.load()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.constellations.count, 0, "starts empty")

        // Seed a claim after initial load
        try seedActiveClaim(claim: "post-reflection claim", confidence: 0.85)

        // Post the notification — the VM's observer should reload
        NotificationCenter.default.post(name: .reflectionRunCompleted, object: nil)

        // Give the main-queue observer block time to fire and reload
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(vm.constellations.count, 1,
                       "VM must reload constellations on .reflectionRunCompleted")
        XCTAssertEqual(vm.constellations[0].label, "post-reflection claim")
    }
}
