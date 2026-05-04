import XCTest
@testable import Nous

final class SkillMatcherTests: XCTestCase {

    func testNilModeReturnsEmpty() {
        let matcher = SkillMatcher()
        let skills = [makeSkill(name: "direction", modes: [.direction])]

        let matches = matcher.matchingSkills(
            from: skills,
            context: SkillMatchContext(mode: nil, turnIndex: 1),
            cap: 5
        )

        XCTAssertEqual(matches, [])
    }

    func testModeMatchFires() {
        let matcher = SkillMatcher()
        let skill = makeSkill(name: "direction", modes: [.direction])

        let matches = matcher.matchingSkills(
            from: [skill],
            context: SkillMatchContext(mode: .direction, turnIndex: 1),
            cap: 5
        )

        XCTAssertEqual(matches, [skill])
    }

    func testDifferentModeIsSkipped() {
        let matcher = SkillMatcher()
        let skill = makeSkill(name: "direction", modes: [.direction])

        let matches = matcher.matchingSkills(
            from: [skill],
            context: SkillMatchContext(mode: .brainstorm, turnIndex: 1),
            cap: 5
        )

        XCTAssertEqual(matches, [])
    }

    func testInactiveSkillIsExcluded() {
        let matcher = SkillMatcher()
        let disabled = makeSkill(name: "disabled", modes: [.direction], state: .disabled)

        let matches = matcher.matchingSkills(
            from: [disabled],
            context: SkillMatchContext(mode: .direction, turnIndex: 1),
            cap: 5
        )

        XCTAssertEqual(matches, [])
    }

    func testCapKeepsHighestPriorityFive() {
        let matcher = SkillMatcher()
        let skills = (1...7).map { index in
            makeSkill(
                name: "skill-\(index)",
                modes: [.direction],
                priority: index * 10
            )
        }

        let matches = matcher.matchingSkills(
            from: skills,
            context: SkillMatchContext(mode: .direction, turnIndex: 1),
            cap: 5
        )

        XCTAssertEqual(matches.map { $0.payload.name }, ["skill-7", "skill-6", "skill-5", "skill-4", "skill-3"])
    }

    func testTurnZeroSkipsModeSkeletonButKeepsAlwaysSkills() {
        let matcher = SkillMatcher()
        let skeleton = makeSkill(name: "direction-skeleton", kind: .mode, modes: [.direction], priority: 90)
        let always = [
            makeSkill(name: "taste-1", kind: .always, modes: [.direction], priority: 80),
            makeSkill(name: "taste-2", kind: .always, modes: [.direction], priority: 70),
            makeSkill(name: "taste-3", kind: .always, modes: [.direction], priority: 60),
            makeSkill(name: "taste-4", kind: .always, modes: [.direction], priority: 50),
            makeSkill(name: "taste-5", kind: .always, modes: [.direction], priority: 40)
        ]

        let matches = matcher.matchingSkills(
            from: [skeleton] + always,
            context: SkillMatchContext(mode: .direction, turnIndex: 0),
            cap: 5
        )

        XCTAssertEqual(matches, always)
    }

    func testTurnOneModeSkeletonFiresAndDisplacesLowestAlwaysSkill() {
        let matcher = SkillMatcher()
        let skeleton = makeSkill(name: "direction-skeleton", kind: .mode, modes: [.direction], priority: 90)
        let always = [
            makeSkill(name: "taste-1", kind: .always, modes: [.direction], priority: 80),
            makeSkill(name: "taste-2", kind: .always, modes: [.direction], priority: 70),
            makeSkill(name: "taste-3", kind: .always, modes: [.direction], priority: 60),
            makeSkill(name: "taste-4", kind: .always, modes: [.direction], priority: 50),
            makeSkill(name: "taste-5", kind: .always, modes: [.direction], priority: 40)
        ]

        let matches = matcher.matchingSkills(
            from: [skeleton] + always,
            context: SkillMatchContext(mode: .direction, turnIndex: 1),
            cap: 5
        )

        XCTAssertEqual(matches, [skeleton] + Array(always.prefix(4)))
    }

    func testEqualPriorityOrdersByNameThenId() {
        let matcher = SkillMatcher()
        let a2 = makeSkill(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "alpha",
            modes: [.direction],
            priority: 70
        )
        let b = makeSkill(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "beta",
            modes: [.direction],
            priority: 70
        )
        let a1 = makeSkill(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "alpha",
            modes: [.direction],
            priority: 70
        )

        let matches = matcher.matchingSkills(
            from: [a2, b, a1],
            context: SkillMatchContext(mode: .direction, turnIndex: 1),
            cap: 5
        )

        XCTAssertEqual(matches, [a1, a2, b])
    }

    private func makeSkill(
        id: UUID = UUID(),
        name: String,
        kind: SkillTrigger.Kind = .always,
        modes: [QuickActionMode],
        priority: Int = 70,
        state: SkillState = .active
    ) -> Skill {
        Skill(
            id: id,
            userId: "alex",
            payload: SkillPayload(
                payloadVersion: 1,
                name: name,
                source: .alex,
                trigger: SkillTrigger(kind: kind, modes: modes, priority: priority),
                action: SkillAction(kind: .promptFragment, content: "Use concrete language."),
                antiPatternExamples: []
            ),
            state: state,
            firedCount: 0,
            createdAt: Date(timeIntervalSince1970: 1_000),
            lastModifiedAt: Date(timeIntervalSince1970: 2_000),
            lastFiredAt: nil
        )
    }
}
