import XCTest
@testable import Nous

final class CitationTraceWiringTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var traceStore: CitationJudgeTraceStore!

    override func setUpWithError() throws {
        nodeStore = try NodeStore(path: ":memory:")
        traceStore = CitationJudgeTraceStore(nodeStore: nodeStore)
    }

    override func tearDown() {
        traceStore = nil
        nodeStore = nil
        super.tearDown()
    }

    func testTraceWriteEmitsRowPerCandidateAtom() throws {
        let conv = UUID()
        let turn = UUID()
        let atom1 = UUID()
        let atom2 = UUID()
        let atom3 = UUID()

        let emitter = CitationTraceEmitter(traceStore: traceStore)
        let candidates: [(atomId: UUID, confidence: Double)] = [
            (atomId: atom1, confidence: 0.85),
            (atomId: atom2, confidence: 0.55),
            (atomId: atom3, confidence: 0.72)
        ]
        let displayed: Set<UUID> = [atom1, atom3]  // atom2 filtered by floor

        try emitter.emit(
            conversationId: conv,
            turnId: turn,
            candidates: candidates,
            displayedIds: displayed
        )

        let rows = try traceStore.byTurn(turnId: turn)
        XCTAssertEqual(rows.count, 3, "One row per candidate, including filtered")
        XCTAssertEqual(rows.filter(\.wasDisplayed).count, 2)
        XCTAssertEqual(rows.first { $0.atomId == atom2 }?.wasDisplayed, false)
    }

    func testEmitWithEmptyCandidatesIsNoop() throws {
        let conv = UUID()
        let turn = UUID()
        let emitter = CitationTraceEmitter(traceStore: traceStore)
        try emitter.emit(conversationId: conv, turnId: turn, candidates: [], displayedIds: [])
        XCTAssertTrue(try traceStore.byTurn(turnId: turn).isEmpty)
    }
}
