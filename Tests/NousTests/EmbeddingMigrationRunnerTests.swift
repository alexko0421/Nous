import XCTest
@testable import Nous

final class EmbeddingMigrationRunnerTests: XCTestCase {
    func test_skipsRowsAlreadyAtCurrentSignature() throws {
        let store = try NodeStore(path: ":memory:")
        let current = "new-sig-v1"
        let stale = "old-sig-v0"
        let staleAtom = MemoryAtom(
            type: .belief, statement: "stale", scope: .global,
            embedding: [1, 0, 0], embeddingSignature: stale
        )
        let currentAtom = MemoryAtom(
            type: .belief, statement: "current", scope: .global,
            embedding: [0, 1, 0], embeddingSignature: current
        )
        try store.insertMemoryAtom(staleAtom)
        try store.insertMemoryAtom(currentAtom)

        let runner = EmbeddingMigrationRunner(
            nodeStore: store,
            embed: { _ in [0, 0, 1] },
            activeSignature: current
        )
        let report = try runner.runIfNeeded(maxAtoms: 10)
        XCTAssertEqual(report.reembedded, 1)
        XCTAssertEqual(report.skippedAlreadyCurrent, 1)
    }

    func test_resumableAcrossRuns() throws {
        let store = try NodeStore(path: ":memory:")
        for i in 0..<5 {
            try store.insertMemoryAtom(MemoryAtom(
                type: .belief, statement: "row-\(i)", scope: .global,
                embedding: [1], embeddingSignature: "old"
            ))
        }
        let runner = EmbeddingMigrationRunner(
            nodeStore: store,
            embed: { _ in [9] },
            activeSignature: "new"
        )
        let r1 = try runner.runIfNeeded(maxAtoms: 2)
        let r2 = try runner.runIfNeeded(maxAtoms: 2)
        let r3 = try runner.runIfNeeded(maxAtoms: 2)
        XCTAssertEqual(r1.reembedded + r2.reembedded + r3.reembedded, 5)
    }
}
