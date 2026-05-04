import XCTest
@testable import Nous

final class ContextEvidenceStewardTests: XCTestCase {
    func testDropsBlankMemoryEvidence() {
        let steward = ContextEvidenceSteward()
        let evidence = MemoryEvidenceSnippet(
            label: "global",
            sourceNodeId: UUID(),
            sourceTitle: "Empty",
            snippet: "   "
        )

        let result = steward.filterMemoryEvidence([evidence], promptQuery: "memory architecture")

        XCTAssertTrue(result.kept.isEmpty)
        XCTAssertEqual(result.assessment.drops.map(\.reason), [.empty])
    }

    func testKeepsEvidenceWithLexicalOverlap() {
        let steward = ContextEvidenceSteward()
        let evidence = MemoryEvidenceSnippet(
            label: "project",
            sourceNodeId: UUID(),
            sourceTitle: "Architecture",
            snippet: "Alex wants raw SQLite ownership for memory architecture."
        )

        let result = steward.filterMemoryEvidence([evidence], promptQuery: "memory architecture")

        XCTAssertEqual(result.kept, [evidence])
        XCTAssertEqual(result.assessment.keptLabels, ["project"])
    }

    func testKeepsChineseEvidenceWithCJKOverlap() {
        let steward = ContextEvidenceSteward()
        let evidence = MemoryEvidenceSnippet(
            label: "conversation",
            sourceNodeId: UUID(),
            sourceTitle: "UIUX 设计师嘅未来",
            snippet: "Alex 之前问过未来 aui 设计师系咪一个好吃香嘅职位。"
        )

        let result = steward.filterMemoryEvidence([evidence], promptQuery: "设计师未来点样")

        XCTAssertEqual(result.kept, [evidence])
        XCTAssertEqual(result.assessment.keptLabels, ["conversation"])
    }

    func testDropsUnrelatedRecentConversation() {
        let steward = ContextEvidenceSteward()
        let recents = [(title: "Shoes", memory: "Alex compared Cloudmonster sizing after class.")]

        let result = steward.filterRecentConversations(
            recents,
            promptQuery: "explain compound and complex sentences"
        )

        XCTAssertTrue(result.kept.isEmpty)
        XCTAssertEqual(result.assessment.drops.map(\.reason), [.offTopic])
    }
}
