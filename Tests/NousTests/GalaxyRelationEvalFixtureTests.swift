import XCTest
@testable import Nous

final class GalaxyRelationEvalFixtureTests: XCTestCase {
    func testLocalRelationJudgeFixture() {
        let judge = GalaxyRelationJudge()

        for fixture in Self.fixtures {
            let verdict = judge.judge(
                source: fixture.source,
                target: fixture.target,
                similarity: fixture.similarity,
                sourceAtoms: fixture.sourceAtoms,
                targetAtoms: fixture.targetAtoms
            )

            XCTAssertEqual(
                verdict?.relationKind,
                fixture.expectedRelationKind,
                fixture.name
            )
            XCTAssertEqual(
                verdict?.sourceAtomId,
                fixture.expectedSourceAtomId,
                "\(fixture.name) source atom"
            )
            XCTAssertEqual(
                verdict?.targetAtomId,
                fixture.expectedTargetAtomId,
                "\(fixture.name) target atom"
            )
        }
    }

    private struct Fixture {
        let name: String
        let source: NousNode
        let target: NousNode
        let similarity: Float
        let sourceAtoms: [MemoryAtom]
        let targetAtoms: [MemoryAtom]
        let expectedRelationKind: GalaxyRelationKind?
        let expectedSourceAtomId: UUID?
        let expectedTargetAtomId: UUID?
    }

    private static let englishPatternSourceAtom = MemoryAtom(
        type: .pattern,
        statement: "Alex turns uncertainty into speed when there is no safety net.",
        scope: .conversation,
        confidence: 0.86
    )

    private static let englishPatternTargetAtom = MemoryAtom(
        type: .insight,
        statement: "Shipping faster is being used to manage uncertainty.",
        scope: .conversation,
        confidence: 0.84
    )

    private static let chineseBoundaryAtom = MemoryAtom(
        type: .boundary,
        statement: "Alex 唔想将 Nous 变成情绪产品",
        scope: .conversation,
        confidence: 0.2
    )

    private static let chineseGoalAtom = MemoryAtom(
        type: .goal,
        statement: "Nous 要避免变成情绪产品，保持工具属性",
        scope: .conversation,
        confidence: 0.2
    )

    private static let unrelatedBoundaryAtom = MemoryAtom(
        type: .boundary,
        statement: "Do not auto-commit code without explicit approval.",
        scope: .conversation,
        confidence: 0.2
    )

    private static let unrelatedGoalAtom = MemoryAtom(
        type: .goal,
        statement: "Move to New York before summer classes start.",
        scope: .conversation,
        confidence: 0.2
    )

    private static var fixtures: [Fixture] {
        [
            Fixture(
                name: "atom-backed same-pattern beats generic similarity",
                source: NousNode(type: .note, title: "School pressure"),
                target: NousNode(type: .conversation, title: "Shipping pressure"),
                similarity: 0.80,
                sourceAtoms: [englishPatternSourceAtom],
                targetAtoms: [englishPatternTargetAtom],
                expectedRelationKind: .samePattern,
                expectedSourceAtomId: englishPatternSourceAtom.id,
                expectedTargetAtomId: englishPatternTargetAtom.id
            ),
            Fixture(
                name: "Chinese overlap supports low-confidence tension",
                source: NousNode(type: .note, title: "Boundary"),
                target: NousNode(type: .conversation, title: "Direction"),
                similarity: 0.10,
                sourceAtoms: [chineseBoundaryAtom],
                targetAtoms: [chineseGoalAtom],
                expectedRelationKind: .tension,
                expectedSourceAtomId: chineseBoundaryAtom.id,
                expectedTargetAtomId: chineseGoalAtom.id
            ),
            Fixture(
                name: "plain semantic similarity falls back to topic",
                source: NousNode(type: .note, title: "Visa planning", content: "F-1 schedule and school workload."),
                target: NousNode(type: .conversation, title: "Class schedule", content: "Santa Monica College classes and build time."),
                similarity: 0.82,
                sourceAtoms: [],
                targetAtoms: [],
                expectedRelationKind: .topicSimilarity,
                expectedSourceAtomId: nil,
                expectedTargetAtomId: nil
            ),
            Fixture(
                name: "weak link without evidence returns nil",
                source: NousNode(type: .note, title: "Music"),
                target: NousNode(type: .conversation, title: "Apartment search"),
                similarity: 0.42,
                sourceAtoms: [],
                targetAtoms: [],
                expectedRelationKind: nil,
                expectedSourceAtomId: nil,
                expectedTargetAtomId: nil
            ),
            Fixture(
                name: "typed atom pair without overlap or confidence returns nil",
                source: NousNode(type: .note, title: "Code policy"),
                target: NousNode(type: .conversation, title: "Move plan"),
                similarity: 0.10,
                sourceAtoms: [unrelatedBoundaryAtom],
                targetAtoms: [unrelatedGoalAtom],
                expectedRelationKind: nil,
                expectedSourceAtomId: nil,
                expectedTargetAtomId: nil
            )
        ]
    }
}
