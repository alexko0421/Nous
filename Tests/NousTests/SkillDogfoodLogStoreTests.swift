import XCTest
@testable import Nous

final class SkillDogfoodLogStoreTests: XCTestCase {
    func testAppendReadsChronologicalEventsAndEncodesOnlySanitizedFields() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDogfoodLogStoreTests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SkillDogfoodLogStore(url: url)
        let first = event(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            recordedAt: Date(timeIntervalSince1970: 100),
            mode: .direction,
            skillName: "inversion-before-commitment"
        )
        let second = event(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            recordedAt: Date(timeIntervalSince1970: 200),
            mode: .plan,
            skillName: "pain-test-before-building"
        )

        try store.record(first)
        try store.record(second)

        let events = try store.loadEvents()
        XCTAssertEqual(events, [first, second])

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("userPrompt"))
        XCTAssertFalse(raw.contains("assistantText"))
        XCTAssertFalse(raw.contains("anchor"))
        XCTAssertFalse(raw.contains("冇呢样会痛唔痛"))
    }

    func testUnsafeSkillNamesAreStoredAsStableAliases() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDogfoodNamePrivacyTests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SkillDogfoodLogStore(url: url)
        let skillID = UUID(uuidString: "12345678-0000-0000-0000-00000000F00D")!
        let unsafeName = "assistantText: secret\nanchor 冇呢样会痛唔痛"
        let event = SkillDogfoodTurnEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            recordedAt: Date(timeIntervalSince1970: 300),
            mode: .direction,
            turnIndex: 2,
            matchedSkills: [
                SkillDogfoodSkillReference(
                    id: skillID,
                    name: unsafeName,
                    priority: 80
                )
            ],
            loadedSkills: [],
            inlineSkills: []
        )

        try store.record(event)

        let events = try store.loadEvents()
        XCTAssertEqual(events.first?.matchedSkills.first?.name, "skill-12345678")

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("assistantText"))
        XCTAssertFalse(raw.contains("anchor"))
        XCTAssertFalse(raw.contains("冇呢样会痛唔痛"))
    }

    func testLoadEventsSkipsMalformedJSONLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDogfoodMalformedLineTests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        try "{\"matchedSkills\":\n".write(to: url, atomically: true, encoding: .utf8)

        let store = SkillDogfoodLogStore(url: url)
        let validEvent = event(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            recordedAt: Date(timeIntervalSince1970: 400),
            mode: .direction,
            skillName: "inversion-before-commitment"
        )
        try store.record(validEvent)

        XCTAssertEqual(try store.loadEvents(), [validEvent])
    }

    func testSummaryCountsRecentTurnsActiveDaysAndTopSkills() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDogfoodSummaryTests-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = SkillDogfoodLogStore(url: url)
        try store.record(event(
            recordedAt: Date(timeIntervalSince1970: 1_000),
            mode: .direction,
            skillName: "inversion-before-commitment"
        ))
        try store.record(event(
            recordedAt: Date(timeIntervalSince1970: 1_000 + 86_400),
            mode: .plan,
            skillName: "pain-test-before-building"
        ))
        try store.record(SkillDogfoodTurnEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            recordedAt: Date(timeIntervalSince1970: 1_000 + 2 * 86_400),
            mode: .brainstorm,
            turnIndex: 3,
            matchedSkills: [],
            loadedSkills: [],
            inlineSkills: []
        ))

        let summary = try store.summary(
            days: 5,
            now: Date(timeIntervalSince1970: 1_000 + 4 * 86_400)
        )

        XCTAssertEqual(summary.turnCount, 3)
        XCTAssertEqual(summary.activeDayCount, 3)
        XCTAssertEqual(summary.zeroSignalDayCount, 2)
        XCTAssertEqual(summary.topSkills.map(\.name), [
            "inversion-before-commitment",
            "pain-test-before-building"
        ])
    }

    func testMissingLogSummarizesAsZeroSignalWindow() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingSkillDogfoodLog-\(UUID().uuidString).jsonl")
        let store = SkillDogfoodLogStore(url: url)

        let summary = try store.summary(
            days: 3,
            now: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertEqual(summary.turnCount, 0)
        XCTAssertEqual(summary.activeDayCount, 0)
        XCTAssertEqual(summary.zeroSignalDayCount, 3)
        XCTAssertEqual(summary.topSkills, [])
    }

    private func event(
        id: UUID = UUID(),
        recordedAt: Date,
        mode: QuickActionMode,
        skillName: String
    ) -> SkillDogfoodTurnEvent {
        let skill = SkillDogfoodSkillReference(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000F00D")!,
            name: skillName,
            priority: 80
        )
        return SkillDogfoodTurnEvent(
            id: id,
            recordedAt: recordedAt,
            mode: mode,
            turnIndex: 2,
            matchedSkills: [skill],
            loadedSkills: [],
            inlineSkills: [skill]
        )
    }
}
