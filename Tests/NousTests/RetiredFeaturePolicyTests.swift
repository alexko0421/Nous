import XCTest
@testable import Nous

final class RetiredFeaturePolicyTests: XCTestCase {
    func testProjectAndGalaxyProductSurfacesAreRetiredByDefault() {
        XCTAssertFalse(RetiredFeaturePolicy.projectSurfacesEnabled)
        XCTAssertFalse(RetiredFeaturePolicy.galaxySurfacesEnabled)
        XCTAssertFalse(RetiredFeaturePolicy.galaxyBackgroundWorkEnabled)
    }

    func testGraphEngineDoesNotWriteEdgesWhenGalaxyBackgroundWorkIsRetired() throws {
        let store = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: store)
        let engine = GraphEngine(nodeStore: store, vectorStore: vectorStore)
        var source = NousNode(type: .note, title: "Source")
        source.embedding = [1, 0, 0]
        var target = NousNode(type: .note, title: "Target")
        target.embedding = [1, 0, 0]
        try store.insertNode(source)
        try store.insertNode(target)

        try engine.regenerateEdges(for: source)

        XCTAssertTrue(try store.fetchAllEdges().isEmpty)
    }
}
