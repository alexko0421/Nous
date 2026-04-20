import XCTest
@testable import Nous

final class ContradictionRecallTests: XCTestCase {

    var store: NodeStore!
    var service: UserMemoryService!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
        service = UserMemoryService(nodeStore: store, llmServiceProvider: { nil })
    }

    override func tearDown() {
        service = nil
        store = nil
        super.tearDown()
    }

    func testContradictionRecallFactsMergesScopedActiveFactsAndDedupesByNarrowestScope() throws {
        let project = Project(title: "Scoped facts")
        try store.insertProject(project)

        let conversation = NousNode(type: .conversation, title: "Chat", content: "", projectId: project.id)
        try store.insertNode(conversation)

        let sharedSource = UUID()
        try store.insertMemoryFactEntry(
            makeFact(
                scope: .global,
                scopeRefId: nil,
                kind: .decision,
                content: "Do not compete on price.",
                confidence: 0.55,
                sourceNodeIds: [sharedSource],
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        )
        try store.insertMemoryFactEntry(
            makeFact(
                scope: .project,
                scopeRefId: project.id,
                kind: .decision,
                content: "Do not compete on price.",
                confidence: 0.82,
                sourceNodeIds: [conversation.id],
                updatedAt: Date(timeIntervalSince1970: 20)
            )
        )
        try store.insertMemoryFactEntry(
            makeFact(
                scope: .conversation,
                scopeRefId: conversation.id,
                kind: .boundary,
                content: "Do not auto-commit code without approval.",
                confidence: 0.91,
                sourceNodeIds: [conversation.id],
                updatedAt: Date(timeIntervalSince1970: 30)
            )
        )
        try store.insertMemoryFactEntry(
            makeFact(
                scope: .conversation,
                scopeRefId: conversation.id,
                kind: .constraint,
                content: "Cash runway is tight.",
                confidence: 0.74,
                sourceNodeIds: [conversation.id],
                updatedAt: Date(timeIntervalSince1970: 25)
            )
        )
        try store.insertMemoryFactEntry(
            makeFact(
                scope: .project,
                scopeRefId: project.id,
                kind: .boundary,
                content: "Archived project boundary",
                status: .archived,
                sourceNodeIds: [project.id],
                updatedAt: Date(timeIntervalSince1970: 40)
            )
        )

        let facts = try service.contradictionRecallFacts(
            projectId: project.id,
            conversationId: conversation.id
        )

        XCTAssertEqual(facts.map(\.kind), [.boundary, .constraint, .decision])
        XCTAssertEqual(facts.map(\.content), [
            "Do not auto-commit code without approval.",
            "Cash runway is tight.",
            "Do not compete on price."
        ])
        XCTAssertEqual(facts.last?.scope, .project,
                       "when identical content exists at multiple scopes, narrower in-scope fact should win over global")
        XCTAssertEqual(Set(facts.last?.sourceNodeIds ?? []), Set([sharedSource, conversation.id]),
                       "dedupe should preserve source evidence from both rows")
    }

    func testContradictionRecallFactsDoesNotFilterTemporaryFacts() throws {
        let conversation = NousNode(type: .conversation, title: "Temp chat", content: "")
        try store.insertNode(conversation)

        try store.insertMemoryFactEntry(
            makeFact(
                scope: .conversation,
                scopeRefId: conversation.id,
                kind: .boundary,
                content: "Do not ship without approval.",
                stability: .temporary,
                updatedAt: Date(timeIntervalSince1970: 5)
            )
        )

        let facts = try service.contradictionRecallFacts(
            projectId: nil,
            conversationId: conversation.id
        )

        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.stability, .temporary,
                       "temporary contradiction facts should still be hard-recalled in Phase 1")
    }

    func testAnnotateContradictionCandidatesMarksTopRankedFactsOnly() {
        let facts = [
            makeFact(kind: .decision, content: "Do not compete on price.", updatedAt: Date(timeIntervalSince1970: 30)),
            makeFact(kind: .boundary, content: "Do not auto-commit code without approval.", updatedAt: Date(timeIntervalSince1970: 20)),
            makeFact(kind: .constraint, content: "Cash runway is tight.", updatedAt: Date(timeIntervalSince1970: 10)),
            makeFact(kind: .constraint, content: "Only work from cafes.", updatedAt: Date(timeIntervalSince1970: 40))
        ]

        let annotated = service.annotateContradictionCandidates(
            currentMessage: "Maybe we should compete on price and auto-commit this small patch.",
            facts: facts,
            maxCandidates: 2
        )

        let marked = annotated.filter(\.isContradictionCandidate)
        XCTAssertEqual(marked.count, 2)
        XCTAssertEqual(Set(marked.map { $0.fact.content }), Set([
            "Do not compete on price.",
            "Do not auto-commit code without approval."
        ]))
        XCTAssertTrue(annotated.first(where: { $0.fact.content == "Cash runway is tight." })?.isContradictionCandidate == false)
        XCTAssertTrue(annotated.first(where: { $0.fact.content == "Only work from cafes." })?.isContradictionCandidate == false)
    }

    func testAnnotateContradictionCandidatesLeavesAllUnmarkedWhenNoOverlap() {
        let facts = [
            makeFact(kind: .decision, content: "Do not compete on price."),
            makeFact(kind: .boundary, content: "Do not auto-commit code without approval.")
        ]

        let annotated = service.annotateContradictionCandidates(
            currentMessage: "Let us redesign the welcome screen colors.",
            facts: facts
        )

        XCTAssertTrue(annotated.allSatisfy { !$0.isContradictionCandidate })
        XCTAssertTrue(annotated.allSatisfy { $0.relevanceScore == 0 })
    }

    private func makeFact(
        scope: MemoryScope = .conversation,
        scopeRefId: UUID? = nil,
        kind: MemoryKind,
        content: String,
        confidence: Double = 0.8,
        status: MemoryStatus = .active,
        stability: MemoryStability = .stable,
        sourceNodeIds: [UUID] = [],
        updatedAt: Date = Date(timeIntervalSince1970: 1)
    ) -> MemoryFactEntry {
        MemoryFactEntry(
            scope: scope,
            scopeRefId: scopeRefId,
            kind: kind,
            content: content,
            confidence: confidence,
            status: status,
            stability: stability,
            sourceNodeIds: sourceNodeIds,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }
}
