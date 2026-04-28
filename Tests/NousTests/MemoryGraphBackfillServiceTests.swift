import XCTest
@testable import Nous

final class MemoryGraphBackfillServiceTests: XCTestCase {

    var store: NodeStore!
    var service: MemoryGraphBackfillService!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
        service = MemoryGraphBackfillService(nodeStore: store)
    }

    override func tearDown() {
        service = nil
        store = nil
        super.tearDown()
    }

    func testBackfillsExistingFactEntriesIntoGraphAtoms() throws {
        let node = NousNode(type: .conversation, title: "Legacy memory")
        try store.insertNode(node)

        try store.insertMemoryFactEntry(MemoryFactEntry(
            scope: .conversation,
            scopeRefId: node.id,
            kind: .decision,
            content: "Cash runway is tight.",
            confidence: 0.91,
            stability: .stable,
            sourceNodeIds: [node.id],
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 12)
        ))
        try store.insertMemoryFactEntry(MemoryFactEntry(
            scope: .conversation,
            scopeRefId: node.id,
            kind: .boundary,
            content: "Do not auto-commit code without approval.",
            confidence: 0.88,
            stability: .stable,
            sourceNodeIds: [node.id],
            createdAt: Date(timeIntervalSince1970: 13),
            updatedAt: Date(timeIntervalSince1970: 14)
        ))

        let report = try service.runIfNeeded()

        XCTAssertEqual(report.scannedFacts, 2)
        XCTAssertEqual(report.insertedAtoms, 2)
        XCTAssertEqual(report.updatedAtoms, 0)

        let atoms = try store.fetchMemoryAtoms().sorted { $0.type.rawValue < $1.type.rawValue }
        XCTAssertEqual(atoms.map(\.type), [.boundary, .decision])
        XCTAssertEqual(Set(atoms.map(\.statement)), [
            "Cash runway is tight.",
            "Do not auto-commit code without approval."
        ])
        XCTAssertTrue(atoms.allSatisfy { $0.scope == .conversation && $0.scopeRefId == node.id })
        XCTAssertTrue(atoms.allSatisfy { $0.status == .active && $0.sourceNodeId == node.id })
        XCTAssertTrue(atoms.allSatisfy { $0.normalizedKey != nil })
    }

    func testBackfillIsIdempotent() throws {
        let node = NousNode(type: .conversation, title: "Idempotent memory")
        try store.insertNode(node)

        try store.insertMemoryFactEntry(MemoryFactEntry(
            scope: .conversation,
            scopeRefId: node.id,
            kind: .constraint,
            content: "Keep the first graph-memory slice small.",
            confidence: 0.82,
            stability: .stable,
            sourceNodeIds: [node.id],
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        ))

        let first = try service.runIfNeeded()
        let second = try service.runIfNeeded()

        XCTAssertEqual(first.insertedAtoms, 1)
        XCTAssertEqual(second.insertedAtoms, 0)
        XCTAssertEqual(second.updatedAtoms, 0)
        XCTAssertEqual(second.unchangedAtoms, 1)
        XCTAssertEqual(try store.fetchMemoryAtoms().count, 1)
    }

    func testBackfillUsesLatestFactStatusForSameContent() throws {
        let node = NousNode(type: .conversation, title: "Stale memory")
        try store.insertNode(node)
        let content = "Do not compete on price."

        try store.insertMemoryFactEntry(MemoryFactEntry(
            scope: .conversation,
            scopeRefId: node.id,
            kind: .decision,
            content: content,
            confidence: 0.8,
            status: .active,
            stability: .stable,
            sourceNodeIds: [node.id],
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        ))
        try store.insertMemoryFactEntry(MemoryFactEntry(
            scope: .conversation,
            scopeRefId: node.id,
            kind: .decision,
            content: content,
            confidence: 0.8,
            status: .archived,
            stability: .stable,
            sourceNodeIds: [node.id],
            createdAt: Date(timeIntervalSince1970: 12),
            updatedAt: Date(timeIntervalSince1970: 13)
        ))

        _ = try service.runIfNeeded()

        let atom = try XCTUnwrap(store.fetchMemoryAtoms().first)
        XCTAssertEqual(atom.statement, content)
        XCTAssertEqual(atom.status, .archived)
        XCTAssertEqual(atom.eventTime, Date(timeIntervalSince1970: 13))
    }

    func testBackfillMakesLegacyRejectionFactsRecallable() throws {
        let oldChat = NousNode(type: .conversation, title: "Rejected scope")
        try store.insertNode(oldChat)
        try store.insertMemoryFactEntry(MemoryFactEntry(
            scope: .conversation,
            scopeRefId: oldChat.id,
            kind: .decision,
            content: "Alex rejected rebuilding the whole retrieval stack.",
            confidence: 0.9,
            stability: .stable,
            sourceNodeIds: [oldChat.id],
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 21)
        ))

        _ = try service.runIfNeeded()

        let atoms = try store.fetchMemoryAtoms()
        XCTAssertEqual(atoms.first?.type, .rejection)

        let memoryService = UserMemoryService(nodeStore: store, llmServiceProvider: { nil })
        let recall = memoryService.currentDecisionGraphRecall(
            currentMessage: "之前否決過咩方案，點解？",
            projectId: nil,
            conversationId: UUID()
        )

        XCTAssertEqual(recall.count, 1)
        XCTAssertTrue(recall[0].contains("Alex rejected rebuilding the whole retrieval stack."))
    }

    func testBackfillDropsMissingSourceNodeReferenceInsteadOfFailing() throws {
        try store.insertMemoryFactEntry(MemoryFactEntry(
            scope: .conversation,
            scopeRefId: UUID(),
            kind: .boundary,
            content: "Do not persist orphan source IDs.",
            confidence: 0.8,
            stability: .stable,
            sourceNodeIds: [UUID()],
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        ))

        _ = try service.runIfNeeded()

        let atom = try XCTUnwrap(store.fetchMemoryAtoms().first)
        XCTAssertNil(atom.sourceNodeId)
    }
}
