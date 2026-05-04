import XCTest
@testable import Nous

final class MemoryAtomEmbeddingBackfillServiceTests: XCTestCase {

    var store: NodeStore!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    /// Backfill must populate `embedding` on atoms that have none, leaving
    /// already-embedded atoms untouched. Without this, atoms written before
    /// the embed function was wired (or before the embedding model loaded)
    /// remain invisible to vector recall forever.
    func testFillsMissingEmbeddingsAndLeavesEmbeddedAtomsAlone() throws {
        let withoutEmbeddingA = MemoryAtom(
            type: .preference,
            statement: "Alex prefers concise feedback.",
            scope: .global,
            status: .active,
            embedding: nil
        )
        let withoutEmbeddingB = MemoryAtom(
            type: .belief,
            statement: "Distractions tax focus heavily.",
            scope: .global,
            status: .active,
            embedding: nil
        )
        let alreadyEmbedded = MemoryAtom(
            type: .preference,
            statement: "Alex prefers JSON for structured outputs.",
            scope: .global,
            status: .active,
            embedding: [0.1, 0.2, 0.3]
        )
        try [withoutEmbeddingA, withoutEmbeddingB, alreadyEmbedded].forEach(store.insertMemoryAtom)

        let stub = stubEmbedder()
        let service = MemoryAtomEmbeddingBackfillService(nodeStore: store, embed: stub.embed)

        let report = try service.runIfNeeded()

        XCTAssertEqual(report.embedded, 2)
        XCTAssertEqual(report.skippedAlreadyEmbedded, 1)

        let embeddedA = try XCTUnwrap(store.fetchMemoryAtom(id: withoutEmbeddingA.id))
        let embeddedB = try XCTUnwrap(store.fetchMemoryAtom(id: withoutEmbeddingB.id))
        let untouched = try XCTUnwrap(store.fetchMemoryAtom(id: alreadyEmbedded.id))

        XCTAssertEqual(embeddedA.embedding, stub.fixed(withoutEmbeddingA.statement))
        XCTAssertEqual(embeddedB.embedding, stub.fixed(withoutEmbeddingB.statement))
        XCTAssertEqual(untouched.embedding, [0.1, 0.2, 0.3])
    }

    /// Backfill must respect the per-run limit so a fresh launch with a
    /// large unembedded corpus doesn't block on running the embedder
    /// thousands of times in one go. Subsequent runs pick up where the
    /// prior run left off.
    func testRespectsBatchLimit() throws {
        for index in 0..<5 {
            let atom = MemoryAtom(
                type: .preference,
                statement: "preference \(index)",
                scope: .global,
                status: .active
            )
            try store.insertMemoryAtom(atom)
        }
        let stub = stubEmbedder()
        let service = MemoryAtomEmbeddingBackfillService(nodeStore: store, embed: stub.embed)

        let report = try service.runIfNeeded(maxAtoms: 2)

        XCTAssertEqual(report.embedded, 2)
        let embeddedCount = try store.fetchMemoryAtoms()
            .filter { $0.embedding != nil }
            .count
        XCTAssertEqual(embeddedCount, 2)

        // Second run picks up the next batch.
        let secondReport = try service.runIfNeeded(maxAtoms: 2)
        XCTAssertEqual(secondReport.embedded, 2)
        XCTAssertEqual(
            try store.fetchMemoryAtoms().filter({ $0.embedding != nil }).count,
            4
        )
    }

    /// When the embed function returns nil (e.g. model not loaded), the
    /// atom must stay unembedded — not crash, not corrupt. A subsequent
    /// run with a working embedder should pick it up.
    func testReturnsZeroEmbeddedWhenEmbedFunctionReturnsNil() throws {
        let atom = MemoryAtom(
            type: .preference,
            statement: "Alex prefers fast iteration.",
            scope: .global,
            status: .active
        )
        try store.insertMemoryAtom(atom)

        let service = MemoryAtomEmbeddingBackfillService(
            nodeStore: store,
            embed: { _ in nil }
        )
        let report = try service.runIfNeeded()

        XCTAssertEqual(report.embedded, 0)
        XCTAssertEqual(report.failed, 1)
        let stored = try XCTUnwrap(store.fetchMemoryAtom(id: atom.id))
        XCTAssertNil(stored.embedding)
    }

    private struct StubEmbedder {
        let fixed: (String) -> [Float]
        let embed: (String) -> [Float]?
    }

    /// Deterministic embedder: maps each statement to a small float vector
    /// derived from its hash so different statements get different
    /// embeddings.
    private func stubEmbedder() -> StubEmbedder {
        let fixed: (String) -> [Float] = { text in
            let h = text.unicodeScalars.reduce(0.0 as Float) { $0 + Float($1.value) }
            return [h, h * 0.5, h * 0.25]
        }
        return StubEmbedder(fixed: fixed, embed: { Optional(fixed($0)) })
    }
}
