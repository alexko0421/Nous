import XCTest
@testable import Nous

final class SkillStoreTests: XCTestCase {

    private var nodeStore: NodeStore!
    private var store: SkillStore!

    override func setUp() {
        super.setUp()
        nodeStore = try! NodeStore(path: ":memory:")
        store = SkillStore(nodeStore: nodeStore)
    }

    override func tearDown() {
        store = nil
        nodeStore = nil
        super.tearDown()
    }

    func testCRUDRoundTrip() throws {
        let skill = makeSkill()
        try store.insertSkill(skill)

        let active = try store.fetchActiveSkills(userId: "alex")
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first, skill)
        XCTAssertEqual(try store.fetchSkill(id: skill.id), skill)

        var updated = skill
        updated.state = .disabled
        updated.lastModifiedAt = Date(timeIntervalSince1970: 3_000)
        try store.updateSkill(updated)

        XCTAssertEqual(try store.fetchActiveSkills(userId: "alex"), [])
        XCTAssertEqual(try store.fetchSkill(id: skill.id), updated)
    }

    func testFetchActiveSkillsScopesByUserId() throws {
        try store.insertSkill(makeSkill(userId: "alex"))
        try store.insertSkill(makeSkill(userId: "casey"))

        let active = try store.fetchActiveSkills(userId: "alex")

        XCTAssertEqual(active.map(\.userId), ["alex"])
    }

    func testFetchAllSkillsIncludesInactiveStatesAndScopesByUserId() throws {
        let active = makeSkill(id: UUID(), userId: "alex", state: .active, firedCount: 1)
        let disabled = makeSkill(id: UUID(), userId: "alex", state: .disabled, firedCount: 2)
        let retired = makeSkill(id: UUID(), userId: "alex", state: .retired, firedCount: 3)
        let otherUser = makeSkill(id: UUID(), userId: "casey", state: .active, firedCount: 4)

        try store.insertSkill(active)
        try store.insertSkill(disabled)
        try store.insertSkill(retired)
        try store.insertSkill(otherUser)

        let fetched = try store.fetchAllSkills(userId: "alex")

        XCTAssertEqual(Set(fetched.map(\.id)), [active.id, disabled.id, retired.id])
        XCTAssertEqual(Set(fetched.map(\.state)), [.active, .disabled, .retired])
        XCTAssertFalse(fetched.contains { $0.id == otherUser.id })
    }

    func testIncrementFiredCountUpdatesCountAndTimestamp() throws {
        let skill = makeSkill()
        try store.insertSkill(skill)

        try store.incrementFiredCount(id: skill.id, firedAt: Date(timeIntervalSince1970: 4_000))
        try store.incrementFiredCount(id: skill.id, firedAt: Date(timeIntervalSince1970: 4_100.25))

        let fetched = try XCTUnwrap(store.fetchSkill(id: skill.id))
        XCTAssertEqual(fetched.firedCount, 2)
        XCTAssertEqual(fetched.lastFiredAt, Date(timeIntervalSince1970: 4_100.25))
    }

    func testInsertRejectsInvalidPayloadVersion() {
        let skill = makeSkill(payload: Self.makePayload(payloadVersion: 2))

        XCTAssertThrowsError(try store.insertSkill(skill)) { error in
            XCTAssertEqual(error as? SkillStoreError, .invalidPayloadVersion(2))
        }
    }

    func testInsertRejectsEmptyModes() {
        let skill = makeSkill(payload: Self.makePayload(modes: []))

        XCTAssertThrowsError(try store.insertSkill(skill)) { error in
            XCTAssertEqual(error as? SkillStoreError, .emptyModes)
        }
    }

    func testInsertRejectsPriorityOutOfRange() {
        let skill = makeSkill(payload: Self.makePayload(priority: 101))

        XCTAssertThrowsError(try store.insertSkill(skill)) { error in
            XCTAssertEqual(error as? SkillStoreError, .priorityOutOfRange(101))
        }
    }

    func testInsertRejectsEmptyActionContent() {
        let skill = makeSkill(payload: Self.makePayload(actionContent: " \n\t "))

        XCTAssertThrowsError(try store.insertSkill(skill)) { error in
            XCTAssertEqual(error as? SkillStoreError, .emptyActionContent)
        }
    }

    func testUpdateRejectsInvalidPayload() throws {
        let skill = makeSkill()
        try store.insertSkill(skill)

        let invalid = makeSkill(id: skill.id, payload: Self.makePayload(modes: []))

        XCTAssertThrowsError(try store.updateSkill(invalid)) { error in
            XCTAssertEqual(error as? SkillStoreError, .emptyModes)
        }
    }

    func testSQLiteCheckRejectsCorruptPayloadJSON() throws {
        XCTAssertThrowsError(
            try insertRawSkillRow(
                id: UUID(),
                payload: "{not json}",
                state: "active"
            )
        )
    }

    func testSQLiteCheckRejectsTypoState() throws {
        XCTAssertThrowsError(
            try insertRawSkillRow(
                id: UUID(),
                payload: validPayloadJSON(),
                state: "actve"
            )
        )
    }

    func testConcurrentDuplicateInsertAttemptsLeaveSingleRow() throws {
        let skill = makeSkill()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "SkillStoreTests.concurrent", attributes: .concurrent)
        let lock = NSLock()
        var successCount = 0
        var errors: [Error] = []

        for _ in 0..<16 {
            group.enter()
            queue.async {
                do {
                    try self.store.insertSkill(skill)
                    lock.lock()
                    successCount += 1
                    lock.unlock()
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(successCount, 1)
        XCTAssertEqual(try store.fetchActiveSkills(userId: "alex").count, 1)
        XCTAssertEqual(errors.count, 15)
        for error in errors {
            XCTAssertFalse(
                error.localizedDescription.contains("cannot start a transaction"),
                "Duplicate insert should fail on UNIQUE constraint, not transaction overlap: \(error)"
            )
        }
    }

    private func makeSkill(
        id: UUID = UUID(),
        userId: String = "alex",
        payload: SkillPayload = SkillStoreTests.makePayload(),
        state: SkillState = .active,
        firedCount: Int = 0,
        createdAt: Date = Date(timeIntervalSince1970: 1_000),
        lastModifiedAt: Date = Date(timeIntervalSince1970: 2_000),
        lastFiredAt: Date? = nil
    ) -> Skill {
        Skill(
            id: id,
            userId: userId,
            payload: payload,
            state: state,
            firedCount: firedCount,
            createdAt: createdAt,
            lastModifiedAt: lastModifiedAt,
            lastFiredAt: lastFiredAt
        )
    }

    private static func makePayload(
        payloadVersion: Int = 1,
        modes: [QuickActionMode] = [.direction],
        priority: Int = 70,
        actionContent: String = "Use concrete language."
    ) -> SkillPayload {
        SkillPayload(
            payloadVersion: payloadVersion,
            name: "concrete-over-generic",
            description: "Keep prompt fragments specific",
            source: .alex,
            trigger: SkillTrigger(
                kind: .always,
                modes: modes,
                priority: priority
            ),
            action: SkillAction(
                kind: .promptFragment,
                content: actionContent
            ),
            rationale: "Specific guidance is more useful.",
            antiPatternExamples: []
        )
    }

    private func validPayloadJSON() -> String {
        """
        {
          "payloadVersion": 1,
          "name": "raw-check-skill",
          "source": "alex",
          "trigger": {
            "kind": "always",
            "modes": ["direction"],
            "priority": 70
          },
          "action": {
            "kind": "promptFragment",
            "content": "Use concrete language."
          },
          "antiPatternExamples": []
        }
        """
    }

    private func insertRawSkillRow(id: UUID, payload: String, state: String) throws {
        let stmt = try nodeStore.rawDatabase.prepare("""
            INSERT INTO skills (id, user_id, payload, state, created_at, last_modified_at)
            VALUES (?, 'alex', ?, ?, 1000, 2000);
        """)
        try stmt.bind(id.uuidString, at: 1)
        try stmt.bind(payload, at: 2)
        try stmt.bind(state, at: 3)
        try stmt.step()
    }
}
