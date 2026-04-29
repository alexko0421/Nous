import XCTest
@testable import Nous

final class SeedSkillImporterTests: XCTestCase {

    private var nodeStore: NodeStore!
    private var store: SkillStore!
    private var temporaryBundleURLs: [URL] = []

    override func setUp() {
        super.setUp()
        nodeStore = try! NodeStore(path: ":memory:")
        store = SkillStore(nodeStore: nodeStore)
    }

    override func tearDown() {
        for url in temporaryBundleURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryBundleURLs = []
        store = nil
        nodeStore = nil
        super.tearDown()
    }

    func testFirstImportInsertsAllSeedRows() throws {
        let rows = makeSeedRows(count: 7)

        try importer(for: rows).importSeeds()

        XCTAssertEqual(try store.fetchActiveSkills(userId: "alex").count, 7)
    }

    func testSecondImportSkipsExistingRows() throws {
        let rows = makeSeedRows(count: 7)
        try importer(for: rows).importSeeds()
        try store.incrementFiredCount(id: rows[0].id, firedAt: Date(timeIntervalSince1970: 5_000))

        try importer(for: rows).importSeeds()

        let fetched = try XCTUnwrap(store.fetchSkill(id: rows[0].id))
        XCTAssertEqual(try store.fetchActiveSkills(userId: "alex").count, 7)
        XCTAssertEqual(fetched.firedCount, 1)
        XCTAssertEqual(fetched.lastFiredAt, Date(timeIntervalSince1970: 5_000))
    }

    func testExistingIdWithModifiedSeedContentIsSkipped() throws {
        let id = fixedUUID(1)
        let firstRow = makeSeedRow(
            id: id,
            name: "direction-skeleton",
            actionContent: "Original seed content."
        )
        try importer(for: [firstRow]).importSeeds()

        let fetched = try XCTUnwrap(store.fetchSkill(id: id))
        let localEdit = Skill(
            id: fetched.id,
            userId: fetched.userId,
            payload: makePayload(
                name: fetched.payload.name,
                actionContent: "Alex local edit."
            ),
            state: fetched.state,
            firedCount: fetched.firedCount,
            createdAt: fetched.createdAt,
            lastModifiedAt: Date(timeIntervalSince1970: 6_000),
            lastFiredAt: fetched.lastFiredAt
        )
        try store.updateSkill(localEdit)

        let changedSeed = makeSeedRow(
            id: id,
            name: "direction-skeleton",
            actionContent: "Changed bundled seed content."
        )
        try importer(for: [changedSeed]).importSeeds()

        let afterImport = try XCTUnwrap(store.fetchSkill(id: id))
        XCTAssertEqual(afterImport.payload.action.content, "Alex local edit.")
        XCTAssertEqual(afterImport.lastModifiedAt, Date(timeIntervalSince1970: 6_000))
    }

    func testNewIdInModifiedSeedFileIsInserted() throws {
        let rows = makeSeedRows(count: 7)
        try importer(for: rows).importSeeds()

        let newRow = makeSeedRow(
            id: fixedUUID(8),
            name: "new-seed-skill",
            actionContent: "New seed content."
        )
        try importer(for: rows + [newRow]).importSeeds()

        XCTAssertEqual(try store.fetchActiveSkills(userId: "alex").count, 8)
        XCTAssertEqual(try store.fetchSkill(id: newRow.id)?.payload.name, "new-seed-skill")
    }

    func testRemovedSeedRowLeavesExistingSkill() throws {
        let rows = makeSeedRows(count: 7)
        try importer(for: rows).importSeeds()

        try importer(for: Array(rows.dropFirst())).importSeeds()

        XCTAssertNotNil(try store.fetchSkill(id: rows[0].id))
        XCTAssertEqual(try store.fetchActiveSkills(userId: "alex").count, 7)
    }

    func testConcurrentImportsDoNotSurfaceDuplicateErrors() throws {
        let importer = try importer(for: makeSeedRows(count: 7))
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "SeedSkillImporterTests.concurrent", attributes: .concurrent)
        let lock = NSLock()
        var errors: [Error] = []

        for _ in 0..<16 {
            group.enter()
            queue.async {
                do {
                    try importer.importSeeds()
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(errors.count, 0)
        XCTAssertEqual(try store.fetchActiveSkills(userId: "alex").count, 7)
    }

    private func importer(for rows: [SeedSkillRow]) throws -> SeedSkillImporter {
        let bundle = try bundle(containing: rows)
        return SeedSkillImporter(store: store, bundle: bundle)
    }

    private func bundle(containing rows: [SeedSkillRow]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeedSkillImporterTests-\(UUID().uuidString).bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.nous.tests.seed-skill-importer.\(UUID().uuidString)</string>
            <key>CFBundleName</key>
            <string>SeedSkillImporterTests</string>
            <key>CFBundlePackageType</key>
            <string>BNDL</string>
        </dict>
        </plist>
        """
        try infoPlist.write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: resources.appendingPathComponent("seed-skills.json"))

        temporaryBundleURLs.append(root)
        return try XCTUnwrap(Bundle(url: root))
    }

    private func makeSeedRows(count: Int) -> [SeedSkillRow] {
        (1...count).map { index in
            makeSeedRow(
                id: fixedUUID(index),
                name: "seed-skill-\(index)",
                actionContent: "Seed content \(index)."
            )
        }
    }

    private func makeSeedRow(
        id: UUID,
        name: String,
        actionContent: String
    ) -> SeedSkillRow {
        SeedSkillRow(
            id: id,
            userId: "alex",
            payload: makePayload(name: name, actionContent: actionContent),
            state: .active
        )
    }

    private func makePayload(
        name: String,
        actionContent: String
    ) -> SkillPayload {
        SkillPayload(
            payloadVersion: 1,
            name: name,
            description: "Seed skill",
            source: .importedFromAnchor,
            trigger: SkillTrigger(
                kind: .always,
                modes: [.direction, .brainstorm, .plan],
                priority: 70
            ),
            action: SkillAction(
                kind: .promptFragment,
                content: actionContent
            ),
            rationale: nil,
            antiPatternExamples: []
        )
    }

    private func fixedUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
