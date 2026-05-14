import XCTest
@testable import Nous

final class FailureSkillRepairRunStoreTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var store: FailureSkillRepairRunStore!

    override func setUp() {
        super.setUp()
        nodeStore = try! NodeStore(path: ":memory:")
        store = FailureSkillRepairRunStore(nodeStore: nodeStore)
    }

    override func tearDown() {
        store = nil
        nodeStore = nil
        super.tearDown()
    }

    func testInsertFetchAndUpdateRepairRun() throws {
        let candidateId = UUID()
        var run = FailureSkillRepairRun(
            id: UUID(),
            candidateId: candidateId,
            status: .requested,
            beadId: nil,
            branchName: "codex/failure-repair-too-forceful-12345678",
            commitSHA: nil,
            prURL: nil,
            logExcerpt: String(repeating: "a", count: 900),
            error: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        try store.insertRun(run)

        var fetched = try XCTUnwrap(store.fetchRun(id: run.id))
        XCTAssertEqual(fetched.status, .requested)
        XCTAssertEqual(fetched.candidateId, candidateId)
        XCTAssertEqual(fetched.logExcerpt?.count, 500)

        run.status = .draftPROpened
        run.beadId = "new-york-test"
        run.commitSHA = "abc123"
        run.prURL = "https://github.com/alexko0421/Nous/pull/99"
        run.logExcerpt = String(repeating: "updated ", count: 200)
        run.error = "done"
        run.updatedAt = Date(timeIntervalSince1970: 20)
        try store.updateRun(run)

        fetched = try XCTUnwrap(store.fetchLatestRun(candidateId: candidateId))
        XCTAssertEqual(fetched.status, .draftPROpened)
        XCTAssertEqual(fetched.beadId, "new-york-test")
        XCTAssertEqual(fetched.commitSHA, "abc123")
        XCTAssertEqual(fetched.prURL, "https://github.com/alexko0421/Nous/pull/99")
        XCTAssertEqual(fetched.logExcerpt?.count, 500)
    }

    func testActiveRunUniquenessBlocksDuplicateRequestedOrRunningRuns() throws {
        let candidateId = UUID()
        let first = makeRun(candidateId: candidateId, status: .requested)
        let second = makeRun(candidateId: candidateId, status: .running)

        try store.insertRun(first)

        XCTAssertThrowsError(try store.insertRun(second))

        var completed = first
        completed.status = .failed
        completed.updatedAt = Date(timeIntervalSince1970: 30)
        try store.updateRun(completed)

        XCTAssertNoThrow(try store.insertRun(second))
        XCTAssertEqual(try store.fetchActiveRun(candidateId: candidateId)?.id, second.id)
    }

    func testCancelActiveRunClearsActiveRunForRetry() throws {
        let candidateId = UUID()
        let run = makeRun(candidateId: candidateId, status: .running)
        try store.insertRun(run)

        try store.cancelActiveRun(id: run.id, updatedAt: Date(timeIntervalSince1970: 40))

        let fetched = try XCTUnwrap(store.fetchRun(id: run.id))
        XCTAssertEqual(fetched.status, .cancelled)
        XCTAssertEqual(fetched.updatedAt, Date(timeIntervalSince1970: 40))
        XCTAssertNil(try store.fetchActiveRun(candidateId: candidateId))
        XCTAssertNoThrow(try store.insertRun(makeRun(candidateId: candidateId, status: .requested)))
    }

    private func makeRun(candidateId: UUID, status: FailureSkillRepairRunStatus) -> FailureSkillRepairRun {
        FailureSkillRepairRun(
            id: UUID(),
            candidateId: candidateId,
            status: status,
            beadId: nil,
            branchName: "codex/failure-repair-test",
            commitSHA: nil,
            prURL: nil,
            logExcerpt: nil,
            error: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }
}
