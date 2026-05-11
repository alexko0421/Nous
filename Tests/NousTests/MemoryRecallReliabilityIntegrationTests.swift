import XCTest
@testable import Nous

final class MemoryRecallReliabilityIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["MEMORY_RECALL_INTEGRATION"] == "1" else {
            throw XCTSkip("Set MEMORY_RECALL_INTEGRATION=1 to run real-model integration tests")
        }
    }

    func test_realModel_cantoneseQueryFindsEnglishAtom() async throws {
        let svc = EmbeddingService()
        try await svc.loadModel()
        let v1 = try svc.embed("我嚟到美国都已经系不可思议嘅啦")
        let v2 = try svc.embed("I made it to the US at all is already remarkable")
        let cos = cosineSimilarity(v1, v2)
        XCTAssertGreaterThan(cos, 0.65, "Cross-lingual paraphrases should land near each other")
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).map(*).reduce(0, +)
        let na = sqrt(a.map { $0 * $0 }.reduce(0, +))
        let nb = sqrt(b.map { $0 * $0 }.reduce(0, +))
        return dot / (na * nb)
    }
}
