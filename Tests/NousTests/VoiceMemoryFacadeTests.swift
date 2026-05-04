import XCTest
@testable import Nous

final class VoiceMemoryFacadeTests: XCTestCase {
    private var store: NodeStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try NodeStore(path: ":memory:")
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    func testRecallRecentConversationsReturnsBoundedSummary() throws {
        let current = NousNode(type: .conversation, title: "Current")
        try store.insertNode(current)
        try insertConversationMemory(
            nodeId: current.id,
            content: "current memory should be excluded",
            updatedAt: Date(timeIntervalSince1970: 900)
        )

        for index in 0..<6 {
            let node = NousNode(type: .conversation, title: "Recent \(index)")
            try store.insertNode(node)
            try insertConversationMemory(
                nodeId: node.id,
                content: "recent memory \(index)",
                updatedAt: Date(timeIntervalSince1970: Double(800 - index))
            )
        }

        let facade = VoiceMemoryFacade(nodeStore: store)
        let output = try facade.recallRecentConversations(
            limit: 99,
            context: VoiceMemoryContext(projectId: nil, conversationId: current.id)
        )
        let lines = output.split(separator: "\n")

        XCTAssertEqual(lines.count, 5)
        XCTAssertTrue(lines.first?.hasPrefix("- Recent 0: ") ?? false)
        XCTAssertFalse(output.contains("Current"))
        XCTAssertLessThanOrEqual(lines.first?.count ?? 0, "- Recent 0: ".count + 360)
    }

    func testRecallRecentConversationsExcludesOtherProjectMemories() throws {
        let projectId = UUID()
        let otherProjectId = UUID()
        try store.insertProject(Project(id: projectId, title: "Nous"))
        try store.insertProject(Project(id: otherProjectId, title: "Other"))
        let current = NousNode(type: .conversation, title: "Current", projectId: projectId)
        let sameProject = NousNode(type: .conversation, title: "Same Project", projectId: projectId)
        let otherProject = NousNode(type: .conversation, title: "Other Project", projectId: otherProjectId)
        let noProject = NousNode(type: .conversation, title: "No Project")
        try store.insertNode(current)
        try store.insertNode(sameProject)
        try store.insertNode(otherProject)
        try store.insertNode(noProject)
        try insertConversationMemory(
            nodeId: sameProject.id,
            content: "same project memory",
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        try insertConversationMemory(
            nodeId: otherProject.id,
            content: "other project memory",
            updatedAt: Date(timeIntervalSince1970: 400)
        )
        try insertConversationMemory(
            nodeId: noProject.id,
            content: "no project memory",
            updatedAt: Date(timeIntervalSince1970: 500)
        )

        let facade = VoiceMemoryFacade(nodeStore: store)
        let output = try facade.recallRecentConversations(
            limit: 5,
            context: VoiceMemoryContext(projectId: projectId, conversationId: current.id)
        )

        XCTAssertEqual(output, "- Same Project: same project memory")
    }

    func testSearchMemoryReturnsFriendlyEmptyState() throws {
        let current = NousNode(type: .conversation, title: "Current")
        try store.insertNode(current)
        let facade = VoiceMemoryFacade(nodeStore: store)

        let output = try facade.searchMemory(
            query: "   ",
            limit: 3,
            context: VoiceMemoryContext(projectId: nil, conversationId: current.id)
        )

        XCTAssertEqual(output, "No matching memory found.")
    }

    func testSearchMemoryUsesExistingScopedMemorySearch() throws {
        let projectId = UUID()
        let otherProjectId = UUID()
        try store.insertProject(Project(id: projectId, title: "Nous"))
        try store.insertProject(Project(id: otherProjectId, title: "Other"))
        let current = NousNode(type: .conversation, title: "Current", projectId: projectId)
        let otherConversation = NousNode(type: .conversation, title: "Other", projectId: projectId)
        try store.insertNode(current)
        try store.insertNode(otherConversation)

        try store.insertMemoryEntry(MemoryEntry(
            scope: .global,
            kind: .decision,
            stability: .stable,
            content: "VOICE global decision",
            updatedAt: Date(timeIntervalSince1970: 100)
        ))
        try store.insertMemoryEntry(MemoryEntry(
            scope: .project,
            scopeRefId: projectId,
            kind: .preference,
            stability: .stable,
            content: "voice project preference",
            updatedAt: Date(timeIntervalSince1970: 300)
        ))
        try store.insertMemoryEntry(MemoryEntry(
            scope: .conversation,
            scopeRefId: current.id,
            kind: .thread,
            stability: .temporary,
            content: "voice current thread",
            updatedAt: Date(timeIntervalSince1970: 200)
        ))
        try store.insertMemoryEntry(MemoryEntry(
            scope: .project,
            scopeRefId: otherProjectId,
            kind: .preference,
            stability: .stable,
            content: "voice other project should not appear",
            updatedAt: Date(timeIntervalSince1970: 400)
        ))
        try store.insertMemoryEntry(MemoryEntry(
            scope: .conversation,
            scopeRefId: otherConversation.id,
            kind: .thread,
            stability: .temporary,
            content: "voice other conversation should not appear",
            updatedAt: Date(timeIntervalSince1970: 500)
        ))

        let facade = VoiceMemoryFacade(nodeStore: store)
        let output = try facade.searchMemory(
            query: " VOICE ",
            limit: 5,
            context: VoiceMemoryContext(projectId: projectId, conversationId: current.id)
        )

        XCTAssertEqual(
            output,
            """
            - preference: voice project preference
            - thread: voice current thread
            - decision: VOICE global decision
            """
        )
    }

    private func insertConversationMemory(
        nodeId: UUID,
        content: String,
        updatedAt: Date
    ) throws {
        try store.insertMemoryEntry(MemoryEntry(
            scope: .conversation,
            scopeRefId: nodeId,
            kind: .thread,
            stability: .temporary,
            content: content,
            sourceNodeIds: [nodeId],
            createdAt: updatedAt,
            updatedAt: updatedAt,
            lastConfirmedAt: updatedAt
        ))
    }
}
