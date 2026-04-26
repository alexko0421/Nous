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
}
