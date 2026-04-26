import Foundation
@testable import Nous

extension NodeStore {
    static func inMemoryForTesting() throws -> NodeStore {
        return try NodeStore(path: ":memory:")
    }

    func insertNodeForTest(id: UUID) throws {
        let n = NousNode(
            id: id, type: .conversation, title: "test",
            content: "", emoji: nil,
            projectId: nil,
            isFavorite: false, createdAt: Date(), updatedAt: Date()
        )
        try insertNode(n)
    }

    func executeRawForTest(_ sql: String) throws {
        try rawDatabase.exec(sql)
    }

    func runSharedEdgeRemovalMigrationForTest() throws {
        try runGalaxyRedesignMigration()
    }

    func countRowsForTest(table: String) throws -> Int {
        let stmt = try rawDatabase.prepare("SELECT COUNT(*) FROM \(table);")
        guard try stmt.step() else { return 0 }
        return stmt.int(at: 0)
    }

    func indexExistsForTest(name: String) throws -> Bool {
        let stmt = try rawDatabase.prepare("SELECT name FROM sqlite_master WHERE type='index' AND name=?;")
        try stmt.bind(name, at: 1)
        return try stmt.step()
    }
}
