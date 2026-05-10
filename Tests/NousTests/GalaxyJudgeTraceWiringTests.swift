import XCTest
@testable import Nous

final class GalaxyJudgeTraceWiringTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var traceStore: EdgeJudgeTraceStore!

    override func setUpWithError() throws {
        nodeStore = try NodeStore(path: ":memory:")
        traceStore = EdgeJudgeTraceStore(nodeStore: nodeStore)
    }

    override func tearDown() {
        traceStore = nil
        nodeStore = nil
        super.tearDown()
    }

    func testJudgeWritesTraceForAtomPath() throws {
        let judge = GalaxyRelationJudge(judgeTraceWriter: traceStore)
        let nodeA = NousNode(type: .note, title: "boundary node")
        let nodeB = NousNode(type: .note, title: "goal node")
        let sourceAtoms = [
            MemoryAtom(type: .boundary, statement: "唔做 ChatGPT 啰嗦句式", scope: .conversation, confidence: 0.5)
        ]
        let targetAtoms = [
            MemoryAtom(type: .goal, statement: "想要简洁回复", scope: .conversation, confidence: 0.5)
        ]

        _ = judge.judge(
            source: nodeA,
            target: nodeB,
            similarity: 0.78,
            sourceAtoms: sourceAtoms,
            targetAtoms: targetAtoms
        )

        let history = try traceStore.history(sourceId: nodeA.id, targetId: nodeB.id, limit: 10)
        XCTAssertEqual(history.count, 1, "Atom-path judge call should emit one trace row")
        XCTAssertEqual(history[0].judgePath, .atom)
        XCTAssertNotNil(history[0].relationKind)
    }

    func testJudgeWritesTraceForFallbackPath() throws {
        let judge = GalaxyRelationJudge(judgeTraceWriter: traceStore)
        let nodeA = NousNode(type: .note, title: "A", content: "same topic")
        let nodeB = NousNode(type: .note, title: "B", content: "same topic")
        _ = judge.judge(
            source: nodeA,
            target: nodeB,
            similarity: 0.78,
            sourceAtoms: [],
            targetAtoms: []
        )

        let history = try traceStore.history(sourceId: nodeA.id, targetId: nodeB.id, limit: 10)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].judgePath, .fallback)
        XCTAssertEqual(history[0].relationKind, GalaxyRelationKind.topicSimilarity.rawValue)
    }

    func testJudgeWritesTraceForRejection() throws {
        let judge = GalaxyRelationJudge(judgeTraceWriter: traceStore)
        let nodeA = NousNode(type: .note, title: "A")
        let nodeB = NousNode(type: .note, title: "B")
        _ = judge.judge(
            source: nodeA,
            target: nodeB,
            similarity: 0.50,
            sourceAtoms: [],
            targetAtoms: []
        )

        let history = try traceStore.history(sourceId: nodeA.id, targetId: nodeB.id, limit: 10)
        XCTAssertEqual(history.count, 1, "Rejection still produces a trace row")
        XCTAssertNil(history[0].relationKind, "Nil relation_kind = judge said no")
        XCTAssertEqual(history[0].judgePath, .fallback)
    }
}
