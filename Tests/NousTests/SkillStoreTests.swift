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

    func testConversationLoadedSkillsTableExistsWithSnapshotColumns() throws {
        let stmt = try nodeStore.rawDatabase.prepare("PRAGMA table_info(conversation_loaded_skills);")
        var names = Set<String>()
        while try stmt.step() {
            if let name = stmt.text(at: 1) {
                names.insert(name)
            }
        }

        XCTAssertEqual(
            names,
            Set(["conversation_id", "skill_id", "name_snapshot", "content_snapshot", "state_at_load", "loaded_at"])
        )
    }

    func testConversationLoadedSkillsCascadeWhenConversationDeleted() throws {
        let conversation = NousNode(type: .conversation, title: "Thread", content: "")
        try nodeStore.insertNode(conversation)
        let skill = makeSkill()
        try store.insertSkill(skill)
        try insertLoadedSkillRow(conversationId: conversation.id, skill: skill)

        try nodeStore.deleteNode(id: conversation.id)

        XCTAssertEqual(try loadedSkillRowCount(conversationId: conversation.id), 0)
    }

    func testConversationLoadedSkillsPersistWhenSourceSkillDeleted() throws {
        let conversation = NousNode(type: .conversation, title: "Thread", content: "")
        try nodeStore.insertNode(conversation)
        let skill = makeSkill()
        try store.insertSkill(skill)
        try insertLoadedSkillRow(conversationId: conversation.id, skill: skill)

        let stmt = try nodeStore.rawDatabase.prepare("DELETE FROM skills WHERE id = ?;")
        try stmt.bind(skill.id.uuidString, at: 1)
        try stmt.step()

        XCTAssertEqual(try loadedSkillRowCount(conversationId: conversation.id), 1)
    }

    func testLoadedSkillsReturnsEmptyForFreshConversation() throws {
        let conversation = NousNode(type: .conversation, title: "Thread", content: "")
        try nodeStore.insertNode(conversation)

        XCTAssertEqual(try store.loadedSkills(in: conversation.id), [])
    }

    func testLoadedSkillsReturnsSnapshotsOrderedByLoadedAt() throws {
        let conversation = NousNode(type: .conversation, title: "Thread", content: "")
        try nodeStore.insertNode(conversation)
        let first = makeSkill(
            id: UUID(),
            payload: Self.makePayload(name: "first", actionContent: "First snapshot.")
        )
        let second = makeSkill(
            id: UUID(),
            payload: Self.makePayload(name: "second", actionContent: "Second snapshot.")
        )
        try store.insertSkill(first)
        try store.insertSkill(second)

        try insertLoadedSkillRow(conversationId: conversation.id, skill: second, loadedAt: 20)
        try insertLoadedSkillRow(conversationId: conversation.id, skill: first, loadedAt: 10)

        let loaded = try store.loadedSkills(in: conversation.id)

        XCTAssertEqual(loaded.map(\.skillID), [first.id, second.id])
        XCTAssertEqual(loaded.map(\.nameSnapshot), ["first", "second"])
        XCTAssertEqual(loaded.map(\.contentSnapshot), ["First snapshot.", "Second snapshot."])
        XCTAssertEqual(loaded.map(\.stateAtLoad), [.active, .active])
        XCTAssertEqual(loaded.map(\.loadedAt), [
            Date(timeIntervalSince1970: 10),
            Date(timeIntervalSince1970: 20)
        ])
    }

    func testLoadedSkillsReturnsSnapshotsAfterSourceSkillDeleted() throws {
        let conversation = NousNode(type: .conversation, title: "Thread", content: "")
        try nodeStore.insertNode(conversation)
        let skill = makeSkill(
            payload: Self.makePayload(name: "stable-snapshot", actionContent: "Keep this exact text.")
        )
        try store.insertSkill(skill)
        try insertLoadedSkillRow(conversationId: conversation.id, skill: skill, loadedAt: 30)

        let stmt = try nodeStore.rawDatabase.prepare("DELETE FROM skills WHERE id = ?;")
        try stmt.bind(skill.id.uuidString, at: 1)
        try stmt.step()

        let loaded = try store.loadedSkills(in: conversation.id)

        XCTAssertEqual(loaded, [
            LoadedSkill(
                skillID: skill.id,
                nameSnapshot: "stable-snapshot",
                contentSnapshot: "Keep this exact text.",
                stateAtLoad: .active,
                loadedAt: Date(timeIntervalSince1970: 30)
            )
        ])
    }

    func testMarkSkillLoadedInsertsSnapshotAndIncrementsFireStats() throws {
        let conversation = NousNode(type: .conversation, title: "Thread", content: "")
        try nodeStore.insertNode(conversation)
        let skill = makeSkill(
            payload: Self.makePayload(name: "load-me", actionContent: "Load this fragment.")
        )
        try store.insertSkill(skill)
        let loadedAt = Date(timeIntervalSince1970: 100)
        let loaded = LoadedSkill(
            skillID: skill.id,
            nameSnapshot: "load-me",
            contentSnapshot: "Load this fragment.",
            stateAtLoad: .active,
            loadedAt: loadedAt
        )

        let result = try store.markSkillLoaded(skillID: skill.id, in: conversation.id, at: loadedAt)

        XCTAssertEqual(result, .inserted(loaded))
        XCTAssertEqual(try store.loadedSkills(in: conversation.id), [loaded])
        let fetched = try XCTUnwrap(store.fetchSkill(id: skill.id))
        XCTAssertEqual(fetched.firedCount, 1)
        XCTAssertEqual(fetched.lastFiredAt, loadedAt)
    }

    func testMarkSkillLoadedIsIdempotentAndDoesNotIncrementTwice() throws {
        let conversation = NousNode(type: .conversation, title: "Thread", content: "")
        try nodeStore.insertNode(conversation)
        let skill = makeSkill()
        try store.insertSkill(skill)
        let firstLoad = Date(timeIntervalSince1970: 100)
        let secondLoad = Date(timeIntervalSince1970: 200)
        let expected = LoadedSkill(
            skillID: skill.id,
            nameSnapshot: skill.payload.name,
            contentSnapshot: skill.payload.action.content,
            stateAtLoad: .active,
            loadedAt: firstLoad
        )

        XCTAssertEqual(
            try store.markSkillLoaded(skillID: skill.id, in: conversation.id, at: firstLoad),
            .inserted(expected)
        )
        XCTAssertEqual(
            try store.markSkillLoaded(skillID: skill.id, in: conversation.id, at: secondLoad),
            .alreadyLoaded(expected)
        )

        XCTAssertEqual(try store.loadedSkills(in: conversation.id), [expected])
        let fetched = try XCTUnwrap(store.fetchSkill(id: skill.id))
        XCTAssertEqual(fetched.firedCount, 1)
        XCTAssertEqual(fetched.lastFiredAt, firstLoad)
    }

    func testMarkSkillLoadedReturnsMissingSkillWithoutSnapshot() throws {
        let conversation = NousNode(type: .conversation, title: "Thread", content: "")
        try nodeStore.insertNode(conversation)

        let result = try store.markSkillLoaded(skillID: UUID(), in: conversation.id, at: Date())

        XCTAssertEqual(result, .missingSkill)
        XCTAssertEqual(try loadedSkillRowCount(conversationId: conversation.id), 0)
    }

    func testMarkSkillLoadedReturnsUnavailableForRetiredSkillWithoutSnapshot() throws {
        let conversation = NousNode(type: .conversation, title: "Thread", content: "")
        try nodeStore.insertNode(conversation)
        let skill = makeSkill(state: .retired, firedCount: 7)
        try store.insertSkill(skill)

        let result = try store.markSkillLoaded(skillID: skill.id, in: conversation.id, at: Date())

        XCTAssertEqual(result, .unavailable(.retired))
        XCTAssertEqual(try loadedSkillRowCount(conversationId: conversation.id), 0)
        let fetched = try XCTUnwrap(store.fetchSkill(id: skill.id))
        XCTAssertEqual(fetched.firedCount, 7)
        XCTAssertNil(fetched.lastFiredAt)
    }

    func testUnloadAllSkillsRemovesConversationSnapshotsOnly() throws {
        let firstConversation = NousNode(type: .conversation, title: "First", content: "")
        let secondConversation = NousNode(type: .conversation, title: "Second", content: "")
        try nodeStore.insertNode(firstConversation)
        try nodeStore.insertNode(secondConversation)
        let firstSkill = makeSkill(id: UUID())
        let secondSkill = makeSkill(id: UUID())
        try store.insertSkill(firstSkill)
        try store.insertSkill(secondSkill)
        try insertLoadedSkillRow(conversationId: firstConversation.id, skill: firstSkill, loadedAt: 10)
        try insertLoadedSkillRow(conversationId: secondConversation.id, skill: secondSkill, loadedAt: 20)

        try store.unloadAllSkills(in: firstConversation.id)

        XCTAssertEqual(try store.loadedSkills(in: firstConversation.id), [])
        XCTAssertEqual(try store.loadedSkills(in: secondConversation.id).map(\.skillID), [secondSkill.id])
    }

    func testInsertRejectsInvalidPayloadVersion() {
        let skill = makeSkill(payload: Self.makePayload(payloadVersion: 3))

        XCTAssertThrowsError(try store.insertSkill(skill)) { error in
            XCTAssertEqual(error as? SkillStoreError, .invalidPayloadVersion(3))
        }
    }

    func testInsertRejectsEmptyModes() {
        let skill = makeSkill(payload: Self.makePayload(modes: []))

        XCTAssertThrowsError(try store.insertSkill(skill)) { error in
            XCTAssertEqual(error as? SkillStoreError, .emptyModes)
        }
    }

    func testInsertAcceptsAnalysisGateWithoutModesWhenCuesArePresent() throws {
        let skill = makeSkill(payload: Self.makeAnalysisGatePayload(cues: ["分析", "blind spot"]))

        try store.insertSkill(skill)

        let fetched = try XCTUnwrap(store.fetchSkill(id: skill.id))
        XCTAssertEqual(fetched.payload.trigger.kind, .analysisGate)
        XCTAssertEqual(fetched.payload.trigger.modes, [])
        XCTAssertEqual(fetched.payload.trigger.cues, ["分析", "blind spot"])
    }

    func testInsertRejectsAnalysisGateWithoutCues() {
        let skill = makeSkill(payload: Self.makeAnalysisGatePayload(cues: []))

        XCTAssertThrowsError(try store.insertSkill(skill)) { error in
            XCTAssertEqual(error as? SkillStoreError, .emptyCues)
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

    func testPayloadVersion1DecodesWithUseWhenNil() throws {
        let payload = try JSONDecoder().decode(SkillPayload.self, from: Data(validPayloadJSON().utf8))

        XCTAssertEqual(payload.payloadVersion, 1)
        XCTAssertNil(payload.useWhen)
    }

    func testPayloadVersion2DecodesWithUseWhen() throws {
        let json = """
        {
          "payloadVersion": 2,
          "name": "lazy-load-skill",
          "description": "A skill loaded only when relevant.",
          "useWhen": "Use when Alex asks for concrete tradeoffs.",
          "source": "alex",
          "trigger": {
            "kind": "always",
            "modes": ["direction"],
            "priority": 70
          },
          "action": {
            "kind": "promptFragment",
            "content": "Name the concrete tradeoff."
          },
          "antiPatternExamples": []
        }
        """

        let payload = try JSONDecoder().decode(SkillPayload.self, from: Data(json.utf8))

        XCTAssertEqual(payload.payloadVersion, 2)
        XCTAssertEqual(payload.useWhen, "Use when Alex asks for concrete tradeoffs.")
    }

    func testPayloadVersion3FailsToDecode() throws {
        let json = """
        {
          "payloadVersion": 3,
          "name": "future-skill",
          "source": "alex",
          "trigger": {
            "kind": "always",
            "modes": ["direction"],
            "priority": 70
          },
          "action": {
            "kind": "promptFragment",
            "content": "Future behavior."
          },
          "antiPatternExamples": []
        }
        """

        XCTAssertThrowsError(try JSONDecoder().decode(SkillPayload.self, from: Data(json.utf8)))
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
        name: String = "concrete-over-generic",
        modes: [QuickActionMode] = [.direction],
        priority: Int = 70,
        actionContent: String = "Use concrete language."
    ) -> SkillPayload {
        SkillPayload(
            payloadVersion: payloadVersion,
            name: name,
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

    private static func makeAnalysisGatePayload(cues: [String]) -> SkillPayload {
        SkillPayload(
            payloadVersion: 2,
            name: "analysis-judge-gate",
            description: "Open judge only when explicit analysis intent is present.",
            useWhen: "Use when Alex asks to analyze, find blind spots, or test whether he is wrong.",
            source: .alex,
            trigger: SkillTrigger(
                kind: .analysisGate,
                modes: [],
                priority: 80,
                cues: cues
            ),
            action: SkillAction(
                kind: .promptFragment,
                content: "Enable judge focus without changing ordinary chat shape."
            ),
            rationale: "Keep casual chat light.",
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

    private func insertLoadedSkillRow(conversationId: UUID, skill: Skill, loadedAt: Double = 1.0) throws {
        let stmt = try nodeStore.rawDatabase.prepare("""
            INSERT INTO conversation_loaded_skills (
                conversation_id, skill_id, name_snapshot, content_snapshot, state_at_load, loaded_at
            )
            VALUES (?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(conversationId.uuidString, at: 1)
        try stmt.bind(skill.id.uuidString, at: 2)
        try stmt.bind(skill.payload.name, at: 3)
        try stmt.bind(skill.payload.action.content, at: 4)
        try stmt.bind(skill.state.rawValue, at: 5)
        try stmt.bind(loadedAt, at: 6)
        try stmt.step()
    }

    private func loadedSkillRowCount(conversationId: UUID) throws -> Int {
        let stmt = try nodeStore.rawDatabase.prepare("""
            SELECT COUNT(*) FROM conversation_loaded_skills WHERE conversation_id = ?;
        """)
        try stmt.bind(conversationId.uuidString, at: 1)
        guard try stmt.step() else { return 0 }
        return stmt.int(at: 0)
    }
}
