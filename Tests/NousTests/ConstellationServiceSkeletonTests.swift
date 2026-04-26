import XCTest
@testable import Nous

final class ConstellationServiceSkeletonTests: XCTestCase {
    func test_serviceInitializesAndReturnsEmptyWhenNoData() throws {
        let store = try NodeStore.inMemoryForTesting()
        let vectorStore = VectorStore(nodeStore: store)
        let svc = ConstellationService(nodeStore: store, vectorStore: vectorStore)

        let result = try svc.loadActiveConstellations()
        XCTAssertEqual(result.count, 0)
    }

    func test_clearEphemeralIsIdempotent() throws {
        let store = try NodeStore.inMemoryForTesting()
        let vectorStore = VectorStore(nodeStore: store)
        let svc = ConstellationService(nodeStore: store, vectorStore: vectorStore)

        svc.clearEphemeral()
        svc.clearEphemeral()  // safe to call again
    }

    func test_releaseEphemeralOnUnknownNodeIsNoOp() throws {
        let store = try NodeStore.inMemoryForTesting()
        let vectorStore = VectorStore(nodeStore: store)
        let svc = ConstellationService(nodeStore: store, vectorStore: vectorStore)

        svc.releaseEphemeral(nodeId: UUID())  // does nothing, doesn't crash
    }
}
