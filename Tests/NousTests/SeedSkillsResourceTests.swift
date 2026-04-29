import XCTest
@testable import Nous

final class SeedSkillsResourceTests: XCTestCase {

    func testSeedSkillsResourceDecodesSevenExpectedRows() throws {
        let rows = try decodeSeedRows()

        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(Set(rows.map(\.id)).count, 7)
        XCTAssertTrue(rows.allSatisfy { $0.userId == "alex" })
        XCTAssertTrue(rows.allSatisfy { $0.state == .active })
        XCTAssertTrue(rows.allSatisfy { $0.payload.payloadVersion == 1 })
        XCTAssertTrue(rows.allSatisfy { !$0.payload.trigger.modes.isEmpty })
        XCTAssertTrue(rows.allSatisfy {
            !$0.payload.action.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })

        let names = rows.map(\.payload.name)
        XCTAssertEqual(
            names,
            [
                "direction-skeleton",
                "brainstorm-skeleton",
                "stoic-cantonese-voice",
                "concrete-over-generic",
                "direct-when-disagreeing",
                "interleave-language",
                "weight-against-default-chat-baseline"
            ]
        )

        let direction = try XCTUnwrap(rows.first { $0.payload.name == "direction-skeleton" })
        XCTAssertEqual(direction.payload.trigger.kind, .mode)
        XCTAssertEqual(direction.payload.trigger.modes, [.direction])
        XCTAssertEqual(direction.payload.trigger.priority, 90)

        let brainstorm = try XCTUnwrap(rows.first { $0.payload.name == "brainstorm-skeleton" })
        XCTAssertEqual(brainstorm.payload.trigger.kind, .mode)
        XCTAssertEqual(brainstorm.payload.trigger.modes, [.brainstorm])
        XCTAssertEqual(brainstorm.payload.trigger.priority, 90)

        let tasteRows = rows.filter { $0.payload.trigger.kind == .always }
        XCTAssertEqual(tasteRows.count, 5)
        XCTAssertTrue(tasteRows.allSatisfy {
            $0.payload.trigger.modes == [.direction, .brainstorm, .plan]
        })
    }

    private func decodeSeedRows() throws -> [SeedSkillRow] {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Sources/Nous/Resources/seed-skills.json")
        return try JSONDecoder().decode([SeedSkillRow].self, from: Data(contentsOf: url))
    }
}
