import XCTest
@testable import Nous

final class QuickActionAddendumResolverTests: XCTestCase {
    func testReturnsAgentAddendumAndMatchedSkillsWithoutInjectingSkillContent() {
        let skill = makeSkill(
            name: "direction-skill",
            mode: .direction,
            payloadVersion: 2,
            content: "Use one concrete next step."
        )
        let resolver = QuickActionAddendumResolver(
            skillStore: StubSkillStore(activeSkills: [skill]),
            skillMatcher: SkillMatcher(),
            skillTracker: nil
        )

        let resolution = resolver.resolution(
            mode: .direction,
            agent: StubAgent(mode: .direction, addendum: "Agent turn rule."),
            turnIndex: 1,
            conversationID: nil
        )

        XCTAssertEqual(resolution.addendum, "Agent turn rule.")
        XCTAssertEqual(resolution.matchedSkills.map(\.id), [skill.id])
        XCTAssertFalse(resolution.addendum?.contains("Use one concrete next step.") ?? false)
    }

    func testLegacyPromptFragmentSkillsAreInjectedIntoAddendum() {
        let skill = makeSkill(
            name: "legacy-direction-skill",
            mode: .direction,
            payloadVersion: 1,
            content: "Use one concrete next step."
        )
        let resolver = QuickActionAddendumResolver(
            skillStore: StubSkillStore(activeSkills: [skill]),
            skillMatcher: SkillMatcher(),
            skillTracker: nil
        )

        let resolution = resolver.resolution(
            mode: .direction,
            agent: StubAgent(mode: .direction, addendum: "Agent turn rule."),
            turnIndex: 1,
            conversationID: nil
        )

        XCTAssertEqual(resolution.matchedSkills.map(\.id), [skill.id])
        XCTAssertTrue(resolution.addendum?.contains("Agent turn rule.") == true)
        XCTAssertTrue(resolution.addendum?.contains("Use one concrete next step.") == true)
    }

    func testReturnsNilWhenNoAgentAddendumAndNoSkillMatches() {
        let resolver = QuickActionAddendumResolver(
            skillStore: StubSkillStore(activeSkills: []),
            skillMatcher: SkillMatcher(),
            skillTracker: nil
        )

        let addendum = resolver.addendum(
            mode: .direction,
            agent: StubAgent(mode: .direction, addendum: nil),
            turnIndex: 1
        )

        XCTAssertNil(addendum)
    }

    func testResolutionIncludesLoadedConversationSkillSnapshots() {
        let conversationID = UUID()
        let loadedSkillID = UUID()
        let loaded = LoadedSkill(
            skillID: loadedSkillID,
            nameSnapshot: "loaded",
            contentSnapshot: "Loaded content.",
            stateAtLoad: .active,
            loadedAt: Date(timeIntervalSince1970: 10)
        )
        let loadedSource = makeSkill(
            id: loadedSkillID,
            name: "loaded",
            mode: .direction,
            payloadVersion: 2,
            content: "Loaded content."
        )
        let resolver = QuickActionAddendumResolver(
            skillStore: StubSkillStore(activeSkills: [loadedSource], loadedSkillsByConversation: [conversationID: [loaded]]),
            skillMatcher: SkillMatcher(),
            skillTracker: nil
        )

        let resolution = resolver.resolution(
            mode: .direction,
            agent: StubAgent(mode: .direction, addendum: nil),
            turnIndex: 1,
            conversationID: conversationID
        )

        XCTAssertEqual(resolution.loadedSkills, [loaded])
    }

    func testResolutionRecordsSanitizedDogfoodEventWithoutChangingAddendum() {
        let conversationID = UUID()
        let matched = makeSkill(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            name: "inline-direction-skill",
            mode: .direction,
            payloadVersion: 1,
            content: "Use one concrete next step."
        )
        let indexed = makeSkill(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
            name: "indexed-direction-skill",
            mode: .direction,
            payloadVersion: 2,
            content: "Load me only when needed."
        )
        let loaded = LoadedSkill(
            skillID: indexed.id,
            nameSnapshot: indexed.payload.name,
            contentSnapshot: indexed.payload.action.content,
            stateAtLoad: .active,
            loadedAt: Date(timeIntervalSince1970: 10)
        )
        let logger = RecordingDogfoodLogger()
        let resolver = QuickActionAddendumResolver(
            skillStore: StubSkillStore(
                activeSkills: [matched, indexed],
                loadedSkillsByConversation: [conversationID: [loaded]]
            ),
            skillMatcher: SkillMatcher(),
            skillTracker: nil,
            dogfoodLogger: logger
        )

        let resolution = resolver.resolution(
            mode: .direction,
            agent: StubAgent(mode: .direction, addendum: "Agent turn rule."),
            turnIndex: 2,
            conversationID: conversationID
        )

        XCTAssertEqual(resolution.addendum, "Agent turn rule.\n\nUse one concrete next step.")
        XCTAssertEqual(logger.events.count, 1)
        XCTAssertEqual(logger.events[0].mode, .direction)
        XCTAssertEqual(logger.events[0].turnIndex, 2)
        XCTAssertEqual(logger.events[0].matchedSkills.map(\.name), [
            "indexed-direction-skill",
            "inline-direction-skill"
        ])
        XCTAssertEqual(logger.events[0].loadedSkills.map(\.name), ["indexed-direction-skill"])
        XCTAssertEqual(logger.events[0].inlineSkills.map(\.name), ["inline-direction-skill"])
        XCTAssertEqual(logger.events[0].matchedSkills.map(\.priority), [70, 70])
    }

    private func makeSkill(
        id: UUID = UUID(),
        name: String,
        mode: QuickActionMode,
        payloadVersion: Int = 1,
        content: String
    ) -> Skill {
        Skill(
            id: id,
            userId: "alex",
            payload: SkillPayload(
                payloadVersion: payloadVersion,
                name: name,
                source: .alex,
                trigger: SkillTrigger(kind: .always, modes: [mode], priority: 70),
                action: SkillAction(kind: .promptFragment, content: content)
            ),
            state: .active,
            firedCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastModifiedAt: Date(timeIntervalSince1970: 1_000),
            lastFiredAt: nil
        )
    }
}

private struct StubAgent: QuickActionAgent {
    let mode: QuickActionMode
    let addendum: String?

    func openingPrompt() -> String {
        "Opening"
    }

    func contextAddendum(turnIndex: Int) -> String? {
        addendum
    }

    func memoryPolicy() -> QuickActionMemoryPolicy {
        .lean
    }

    func turnDirective(
        parsed: ClarificationContent,
        turnIndex: Int
    ) -> QuickActionTurnDirective {
        .complete
    }
}

private final class StubSkillStore: SkillStoring {
    private let activeSkills: [Skill]
    private let loadedSkillsByConversation: [UUID: [LoadedSkill]]

    init(activeSkills: [Skill], loadedSkillsByConversation: [UUID: [LoadedSkill]] = [:]) {
        self.activeSkills = activeSkills
        self.loadedSkillsByConversation = loadedSkillsByConversation
    }

    func fetchAllSkills(userId: String) throws -> [Skill] {
        activeSkills
    }

    func fetchActiveSkills(userId: String) throws -> [Skill] {
        activeSkills
    }

    func fetchSkill(id: UUID) throws -> Skill? {
        activeSkills.first { $0.id == id }
    }

    func loadedSkills(in conversationID: UUID) throws -> [LoadedSkill] {
        loadedSkillsByConversation[conversationID] ?? []
    }

    func markSkillLoaded(skillID: UUID, in conversationID: UUID, at loadedAt: Date) throws -> MarkSkillLoadedResult {
        .missingSkill
    }

    func unloadAllSkills(in conversationID: UUID) throws {}

    func insertSkill(_ skill: Skill) throws {}
    func updateSkill(_ skill: Skill) throws {}
    func setSkillState(id: UUID, state: SkillState) throws {}
    func incrementFiredCount(id: UUID, firedAt: Date) throws {}
}

private final class RecordingDogfoodLogger: SkillDogfoodLogging {
    private(set) var events: [SkillDogfoodTurnEvent] = []

    func record(_ event: SkillDogfoodTurnEvent) throws {
        events.append(event)
    }
}
