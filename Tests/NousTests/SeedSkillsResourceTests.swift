import XCTest
@testable import Nous

final class SeedSkillsResourceTests: XCTestCase {

    func testSeedSkillsResourceDecodesExpectedRows() throws {
        let rows = try decodeSeedRows()

        XCTAssertEqual(rows.count, 13)
        XCTAssertEqual(Set(rows.map(\.id)).count, 13)
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
                "brainstorm-5d-thinking-scaffold",
                "stoic-cantonese-voice",
                "concrete-over-generic",
                "direct-when-disagreeing",
                "interleave-language",
                "weight-against-default-chat-baseline",
                "analysis-judge-gate",
                "pain-test-before-building",
                "inversion-before-commitment",
                "problem-tree-seven-step-analysis",
                "study-skeleton"
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

        let brainstorm5D = try XCTUnwrap(rows.first { $0.payload.name == "brainstorm-5d-thinking-scaffold" })
        XCTAssertEqual(brainstorm5D.id, UUID(uuidString: "00000000-0000-0000-0000-000000000013"))
        XCTAssertEqual(brainstorm5D.payload.payloadVersion, 1)
        XCTAssertEqual(brainstorm5D.payload.trigger.kind, .mode)
        XCTAssertEqual(brainstorm5D.payload.trigger.modes, [.brainstorm])
        XCTAssertEqual(brainstorm5D.payload.trigger.priority, 88)
        XCTAssertTrue(brainstorm5D.payload.action.content.contains("BRAINSTORM 5D THINKING SCAFFOLD"))
        XCTAssertTrue(brainstorm5D.payload.action.content.contains("premature closure"))
        XCTAssertTrue(brainstorm5D.payload.action.content.contains("inner individual"))
        XCTAssertTrue(brainstorm5D.payload.action.content.contains("collective culture"))
        XCTAssertTrue(brainstorm5D.payload.action.content.contains("Time:"))

        let tasteRows = rows.filter { $0.payload.trigger.kind == .always }
        XCTAssertEqual(tasteRows.count, 8)
        let broadTasteRows = tasteRows.filter {
            $0.payload.trigger.modes == [.direction, .brainstorm, .plan, .study]
        }
        XCTAssertEqual(broadTasteRows.count, 5)

        let analysisGate = try XCTUnwrap(rows.first { $0.payload.name == "analysis-judge-gate" })
        XCTAssertEqual(analysisGate.payload.payloadVersion, 2)
        XCTAssertEqual(analysisGate.payload.trigger.kind, .analysisGate)
        XCTAssertEqual(analysisGate.payload.trigger.modes, [])
        XCTAssertTrue(analysisGate.payload.trigger.cues.contains("分析"))
        XCTAssertTrue(analysisGate.payload.trigger.cues.contains("blind spot"))
        XCTAssertFalse(analysisGate.payload.trigger.cues.contains("啱唔啱"))
        XCTAssertFalse(analysisGate.payload.trigger.cues.contains("对不对"))
        XCTAssertFalse(analysisGate.payload.trigger.cues.contains("我错"))

        let painTest = try XCTUnwrap(rows.first { $0.payload.name == "pain-test-before-building" })
        XCTAssertEqual(painTest.id, UUID(uuidString: "00000000-0000-0000-0000-000000000009"))
        XCTAssertEqual(painTest.payload.payloadVersion, 1)
        XCTAssertEqual(painTest.payload.trigger.kind, .always)
        XCTAssertEqual(painTest.payload.trigger.modes, [.plan])
        XCTAssertEqual(painTest.payload.trigger.priority, 80)
        XCTAssertTrue(painTest.payload.action.content.contains("冇呢樣嘢"))

        let inversion = try XCTUnwrap(rows.first { $0.payload.name == "inversion-before-commitment" })
        XCTAssertEqual(inversion.id, UUID(uuidString: "00000000-0000-0000-0000-000000000010"))
        XCTAssertEqual(inversion.payload.payloadVersion, 1)
        XCTAssertEqual(inversion.payload.trigger.kind, .always)
        XCTAssertEqual(inversion.payload.trigger.modes, [.direction])
        XCTAssertEqual(inversion.payload.trigger.priority, 80)
        XCTAssertTrue(inversion.payload.action.content.contains("worst version"))

        let problemTree = try XCTUnwrap(rows.first { $0.payload.name == "problem-tree-seven-step-analysis" })
        XCTAssertEqual(problemTree.id, UUID(uuidString: "00000000-0000-0000-0000-000000000011"))
        XCTAssertEqual(problemTree.payload.payloadVersion, 1)
        XCTAssertEqual(problemTree.payload.trigger.kind, .always)
        XCTAssertEqual(problemTree.payload.trigger.modes, [.direction, .plan])
        XCTAssertEqual(problemTree.payload.trigger.priority, 85)
        XCTAssertTrue(problemTree.payload.action.content.contains("hidden thinking spine"))
        XCTAssertTrue(problemTree.payload.action.content.contains("陈述问题"))
        XCTAssertTrue(problemTree.payload.action.content.contains("讲清楚"))
        XCTAssertTrue(problemTree.payload.action.content.contains("Brainstorm"))
        XCTAssertFalse(problemTree.payload.trigger.modes.contains(.study))

        let study = try XCTUnwrap(rows.first { $0.payload.name == "study-skeleton" })
        XCTAssertEqual(study.id, UUID(uuidString: "00000000-0000-0000-0000-000000000012"))
        XCTAssertEqual(study.payload.payloadVersion, 1)
        XCTAssertEqual(study.payload.trigger.kind, .mode)
        XCTAssertEqual(study.payload.trigger.modes, [.study])
        XCTAssertEqual(study.payload.trigger.priority, 90)
        XCTAssertTrue(study.payload.action.content.contains("STUDY MODE QUALITY CONTRACT"))
        XCTAssertTrue(study.payload.action.content.contains("faithful to the source"))
        XCTAssertTrue(study.payload.action.content.contains("Do not turn the reading into Direction, Brainstorm, or Plan unless Alex asks"))
        XCTAssertTrue(study.payload.action.content.contains("Connect the insight to Alex's product/thinking context only after the source is clear"))
        XCTAssertTrue(study.payload.action.content.contains("沉淀"))
        XCTAssertFalse(study.payload.action.content.contains("problem-tree"))
        XCTAssertFalse(study.payload.action.content.contains("seven-step"))
        XCTAssertFalse(study.payload.action.content.contains("陈述问题"))
        XCTAssertFalse(study.payload.action.content.contains("制定详细工作计划"))
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
