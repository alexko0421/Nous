import XCTest
@testable import Nous

final class SkillTrackerTests: XCTestCase {

    func testRecordFireIncrementsEachSkillAndSwallowsFailures() async throws {
        let failingId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let store = RecordingSkillStore(failingIds: [failingId])
        let tracker = SkillTracker(store: store)
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            failingId,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        ]

        try await tracker.recordFire(skillIds: ids)

        XCTAssertEqual(store.incrementedIds, ids)
        XCTAssertEqual(store.firedDates.count, ids.count)
    }
}

private final class RecordingSkillStore: SkillStoring {
    struct IncrementError: Error {}

    private let failingIds: Set<UUID>
    private(set) var incrementedIds: [UUID] = []
    private(set) var firedDates: [Date] = []

    init(failingIds: Set<UUID> = []) {
        self.failingIds = failingIds
    }

    func fetchAllSkills(userId: String) throws -> [Skill] {
        []
    }

    func fetchActiveSkills(userId: String) throws -> [Skill] {
        []
    }

    func fetchSkill(id: UUID) throws -> Skill? {
        nil
    }

    func insertSkill(_ skill: Skill) throws {}

    func updateSkill(_ skill: Skill) throws {}

    func setSkillState(id: UUID, state: SkillState) throws {}

    func incrementFiredCount(id: UUID, firedAt: Date) throws {
        incrementedIds.append(id)
        firedDates.append(firedAt)

        if failingIds.contains(id) {
            throw IncrementError()
        }
    }
}
