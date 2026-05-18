import XCTest
@testable import Nous

final class TopicContextStoreTests: XCTestCase {
    var store: NodeStore!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func testUpsertsAndFetchesTopicAssignmentWithoutRawPromptContent() throws {
        let node = NousNode(type: .conversation, title: "SMC visa planning")
        try store.insertNode(node)

        let assignment = TopicContextAssignment(
            targetType: .conversation,
            targetId: node.id,
            primaryLane: .education,
            secondaryLanes: [.personalReflection],
            subtopicLabel: "school / visa / learning depth",
            confidence: 0.84,
            source: .deterministic,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        try store.upsertTopicContextAssignment(assignment)

        let fetched = try XCTUnwrap(store.fetchTopicContextAssignment(
            targetType: .conversation,
            targetId: node.id
        ))
        XCTAssertEqual(fetched.primaryLane, .education)
        XCTAssertEqual(fetched.secondaryLanes, [.personalReflection])
        XCTAssertEqual(fetched.subtopicLabel, "school / visa / learning depth")
        XCTAssertEqual(fetched.confidence, 0.84, accuracy: 0.001)

        let rawRows = try store.debugTopicContextAssignmentRows()
        XCTAssertEqual(rawRows.count, 1)
        XCTAssertFalse(rawRows[0].contains("F-1 visa status means I need a cleaner study plan"))
        XCTAssertFalse(rawRows[0].contains("userPrompt"))
        XCTAssertFalse(rawRows[0].contains("assistantText"))
    }

    func testFetchesAssignmentsByLaneNewestFirst() throws {
        let older = TopicContextAssignment(
            targetType: .memoryAtom,
            targetId: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            primaryLane: .finance,
            secondaryLanes: [],
            subtopicLabel: "stock FOMO",
            confidence: 0.8,
            source: .deterministic,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = TopicContextAssignment(
            targetType: .memoryAtom,
            targetId: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            primaryLane: .finance,
            secondaryLanes: [],
            subtopicLabel: "spending loop",
            confidence: 0.85,
            source: .deterministic,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        try store.upsertTopicContextAssignment(older)
        try store.upsertTopicContextAssignment(newer)

        let matches = try store.fetchTopicContextAssignments(
            primaryLane: .finance,
            targetType: .memoryAtom,
            limit: 10
        )

        XCTAssertEqual(matches.map(\.targetId), [newer.targetId, older.targetId])
    }

    func testMemoryAtomWriteClassifiesAndClearsStaleTopicAssignment() throws {
        var atom = MemoryAtom(
            type: .decision,
            statement: "Stock FOMO creates bad spending loops.",
            scope: .global,
            confidence: 0.9,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        try store.insertMemoryAtom(atom)

        var fetched = try XCTUnwrap(store.fetchTopicContextAssignment(
            targetType: .memoryAtom,
            targetId: atom.id
        ))
        XCTAssertEqual(fetched.primaryLane, .finance)

        atom.statement = "plain note with no durable topic signal"
        atom.updatedAt = Date(timeIntervalSince1970: 20)
        try store.updateMemoryAtom(atom)

        XCTAssertNil(try store.fetchTopicContextAssignment(
            targetType: .memoryAtom,
            targetId: atom.id
        ), "updating an atom to a general fallback should not leave a stale topic lane")
    }
}
