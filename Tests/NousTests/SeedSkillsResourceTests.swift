import XCTest
@testable import Nous

final class SeedSkillsResourceTests: XCTestCase {

    func testSeedSkillsResourceDecodesExpectedRows() throws {
        let rows = try decodeSeedRows()

        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(Set(rows.map(\.id)).count, 8)
        XCTAssertTrue(rows.allSatisfy { $0.userId == "alex" })
        XCTAssertTrue(rows.allSatisfy { $0.state == .active })
        XCTAssertTrue(rows.allSatisfy { (1...2).contains($0.payload.payloadVersion) })
        XCTAssertTrue(rows.allSatisfy {
            switch $0.payload.trigger.kind {
            case .analysisGate:
                return $0.payload.trigger.modes.isEmpty && !$0.payload.trigger.cues.isEmpty
            case .always, .mode:
                return !$0.payload.trigger.modes.isEmpty
            }
        })
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
                "weight-against-default-chat-baseline",
                "analysis-judge-gate"
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

        let analysisGate = try XCTUnwrap(rows.first { $0.payload.name == "analysis-judge-gate" })
        XCTAssertEqual(analysisGate.payload.payloadVersion, 2)
        XCTAssertEqual(analysisGate.payload.trigger.kind, .analysisGate)
        XCTAssertEqual(analysisGate.payload.trigger.modes, [])
        XCTAssertTrue(analysisGate.payload.trigger.cues.contains("分析"))
        XCTAssertTrue(analysisGate.payload.trigger.cues.contains("blind spot"))
        XCTAssertFalse(analysisGate.payload.trigger.cues.contains("啱唔啱"))
        XCTAssertFalse(analysisGate.payload.trigger.cues.contains("对不对"))
        XCTAssertFalse(analysisGate.payload.trigger.cues.contains("我错"))
    }

    func testSeedSkillsResourceImportsActiveAnalysisGate() throws {
        let rows = try decodeSeedRows()
        let nodeStore = try NodeStore(path: ":memory:")
        let skillStore = SkillStore(nodeStore: nodeStore)
        let bundle = try temporaryBundle(containing: rows)
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }

        try SeedSkillImporter(store: skillStore, bundle: bundle).importSeeds()

        let active = try skillStore.fetchActiveSkills(userId: "alex")
        let analysisGate = try XCTUnwrap(active.first { $0.payload.name == "analysis-judge-gate" })
        XCTAssertEqual(active.count, rows.count)
        XCTAssertEqual(analysisGate.state, .active)
        XCTAssertEqual(analysisGate.payload.trigger.kind, .analysisGate)
        XCTAssertEqual(analysisGate.payload.trigger.modes, [])
        XCTAssertTrue(analysisGate.payload.trigger.cues.contains("分析"))
        XCTAssertTrue(analysisGate.payload.trigger.cues.contains("blind spot"))
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

    private func temporaryBundle(containing rows: [SeedSkillRow]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeedSkillsResourceTests-\(UUID().uuidString).bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.nous.tests.seed-skills-resource</string>
        </dict>
        </plist>
        """
        try infoPlist.write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        try JSONEncoder().encode(rows).write(to: resources.appendingPathComponent("seed-skills.json"))

        return try XCTUnwrap(Bundle(url: root))
    }
}
