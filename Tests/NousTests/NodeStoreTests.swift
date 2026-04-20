import XCTest
@testable import Nous

final class NodeStoreTests: XCTestCase {

    var store: NodeStore!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeNode(
        title: String = "Test Node",
        type: NodeType = .note,
        content: String = "Some content",
        projectId: UUID? = nil,
        isFavorite: Bool = false
    ) -> NousNode {
        NousNode(type: type, title: title, content: content, projectId: projectId, isFavorite: isFavorite)
    }

    // MARK: - Node Tests

    func testInsertAndFetchNode() throws {
        var node = makeNode(title: "Hello", content: "World", isFavorite: true)
        node.emoji = "💼"
        try store.insertNode(node)

        let fetched = try store.fetchNode(id: node.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, node.id)
        XCTAssertEqual(fetched?.title, "Hello")
        XCTAssertEqual(fetched?.content, "World")
        XCTAssertEqual(fetched?.emoji, "💼")
        XCTAssertEqual(fetched?.isFavorite, true)
        XCTAssertEqual(fetched?.type, .note)
    }

    func testUpdateNode() throws {
        var node = makeNode(title: "Original", content: "Before")
        try store.insertNode(node)

        node.title = "Updated Title"
        node.content = "After"
        node.emoji = "💡"
        node.updatedAt = Date()
        try store.updateNode(node)

        let fetched = try store.fetchNode(id: node.id)
        XCTAssertEqual(fetched?.title, "Updated Title")
        XCTAssertEqual(fetched?.content, "After")
        XCTAssertEqual(fetched?.emoji, "💡")
    }

    func testDeleteNode() throws {
        let node = makeNode()
        try store.insertNode(node)

        try store.deleteNode(id: node.id)

        let fetched = try store.fetchNode(id: node.id)
        XCTAssertNil(fetched)
    }

    func testNodeContentPreservesEmbeddedNullBytes() throws {
        let content = "alpha\u{0000}omega"
        let node = makeNode(title: "Binary-safe", content: content)
        try store.insertNode(node)

        let fetched = try store.fetchNode(id: node.id)
        XCTAssertEqual(fetched?.content, content)
    }

    func testFetchAllNodes() throws {
        let node1 = makeNode(title: "Node 1")
        let node2 = makeNode(title: "Node 2")
        try store.insertNode(node1)
        try store.insertNode(node2)

        let all = try store.fetchAllNodes()
        XCTAssertEqual(all.count, 2)
    }

    func testFetchNodesByProject() throws {
        let project = Project(title: "My Project")
        try store.insertProject(project)

        let nodeWithProject = makeNode(title: "In Project", projectId: project.id)
        let nodeWithout = makeNode(title: "No Project")
        try store.insertNode(nodeWithProject)
        try store.insertNode(nodeWithout)

        let results = try store.fetchNodes(projectId: project.id)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "In Project")
    }

    func testFetchFavorites() throws {
        let fav = makeNode(title: "Favorite", isFavorite: true)
        let notFav = makeNode(title: "Not Favorite", isFavorite: false)
        try store.insertNode(fav)
        try store.insertNode(notFav)

        let favorites = try store.fetchFavorites()
        XCTAssertEqual(favorites.count, 1)
        XCTAssertEqual(favorites.first?.title, "Favorite")
    }

    func testFetchRecentConversationsExcludesCurrentNode() throws {
        let older = makeNode(title: "Older Chat", type: .conversation, content: "Old transcript")
        try store.insertNode(older)

        var newer = makeNode(title: "Newer Chat", type: .conversation, content: "New transcript")
        newer.updatedAt = Date().addingTimeInterval(60)
        try store.insertNode(newer)

        let recents = try store.fetchRecentConversations(limit: 5, excludingId: newer.id)

        XCTAssertEqual(recents.count, 1)
        XCTAssertEqual(recents.first?.id, older.id)
    }

    /// Recent continuity feed must read the active conversation entry, not the
    /// raw transcript and not the frozen v2.1 blob. The blob is intentionally
    /// seeded with different content here to prove the read path now follows
    /// `memory_entries`.
    func testFetchRecentConversationMemoriesUsesActiveEntryNotTranscriptOrBlob() throws {
        let chatWithMemory = makeNode(
            title: "Chat with memory",
            type: .conversation,
            content: "Alex: hi\n\nNous: hi there, raw transcript leaks should not survive"
        )
        try store.insertNode(chatWithMemory)
        try store.saveConversationMemory(
            ConversationMemory(
                nodeId: chatWithMemory.id,
                content: "OLD frozen blob content",
                updatedAt: Date(timeIntervalSince1970: 1000)
            )
        )
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: chatWithMemory.id,
                kind: .thread,
                stability: .temporary,
                content: "- Alex wants Nous to remember evidence-only notes",
                sourceNodeIds: [chatWithMemory.id],
                createdAt: Date(timeIntervalSince1970: 1000),
                updatedAt: Date(timeIntervalSince1970: 1000),
                lastConfirmedAt: Date(timeIntervalSince1970: 1000)
            )
        )

        // A chat with no active entry yet — must be excluded even if transcript exists.
        let chatWithoutMemory = makeNode(
            title: "No memory yet",
            type: .conversation,
            content: "Alex: test\n\nNous: reply"
        )
        try store.insertNode(chatWithoutMemory)

        let recents = try store.fetchRecentConversationMemories(limit: 5)

        XCTAssertEqual(recents.count, 1, "chat without active conversation entry must be skipped")
        XCTAssertEqual(recents.first?.title, "Chat with memory")
        XCTAssertEqual(recents.first?.memory,
                       "- Alex wants Nous to remember evidence-only notes")
        XCTAssertFalse(recents.first?.memory.contains("OLD frozen blob content") ?? true,
                       "recent feed must not read the stale blob")
        XCTAssertFalse(recents.first?.memory.contains("Nous:") ?? true,
                       "raw assistant marker must not reach the recent feed")
    }

    func testFetchRecentConversationMemoriesExcludesCurrentNode() throws {
        let older = makeNode(title: "Older", type: .conversation)
        try store.insertNode(older)
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: older.id,
                kind: .thread,
                stability: .temporary,
                content: "- older memory",
                sourceNodeIds: [older.id],
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100),
                lastConfirmedAt: Date(timeIntervalSince1970: 100)
            )
        )

        let current = makeNode(title: "Current", type: .conversation)
        try store.insertNode(current)
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: current.id,
                kind: .thread,
                stability: .temporary,
                content: "- current memory",
                sourceNodeIds: [current.id],
                createdAt: Date(timeIntervalSince1970: 200),
                updatedAt: Date(timeIntervalSince1970: 200),
                lastConfirmedAt: Date(timeIntervalSince1970: 200)
            )
        )

        let recents = try store.fetchRecentConversationMemories(limit: 5, excludingId: current.id)
        XCTAssertEqual(recents.count, 1)
        XCTAssertEqual(recents.first?.title, "Older")
    }

    func testFetchRecentConversationMemoriesSkipsSupersededEntries() throws {
        let activeChat = makeNode(title: "Active", type: .conversation)
        try store.insertNode(activeChat)
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: activeChat.id,
                kind: .thread,
                stability: .temporary,
                content: "- active memory",
                sourceNodeIds: [activeChat.id],
                createdAt: Date(timeIntervalSince1970: 200),
                updatedAt: Date(timeIntervalSince1970: 200),
                lastConfirmedAt: Date(timeIntervalSince1970: 200)
            )
        )

        let staleChat = makeNode(title: "Stale", type: .conversation)
        try store.insertNode(staleChat)
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: staleChat.id,
                kind: .thread,
                stability: .temporary,
                status: .superseded,
                content: "- stale memory",
                sourceNodeIds: [staleChat.id],
                createdAt: Date(timeIntervalSince1970: 300),
                updatedAt: Date(timeIntervalSince1970: 300),
                lastConfirmedAt: Date(timeIntervalSince1970: 300)
            )
        )

        let recents = try store.fetchRecentConversationMemories(limit: 5)
        XCTAssertEqual(recents.count, 1)
        XCTAssertEqual(recents.first?.title, "Active")
    }

    // MARK: - Message Tests

    func testInsertAndFetchMessages() throws {
        let node = makeNode()
        try store.insertNode(node)

        let msg1 = Message(nodeId: node.id, role: .user, content: "Hello",
                           timestamp: Date(timeIntervalSince1970: 1000))
        let msg2 = Message(nodeId: node.id, role: .assistant, content: "Hi there",
                           timestamp: Date(timeIntervalSince1970: 2000))
        try store.insertMessage(msg1)
        try store.insertMessage(msg2)

        let messages = try store.fetchMessages(nodeId: node.id)
        XCTAssertEqual(messages.count, 2)
        // Verify ASC order by timestamp
        XCTAssertEqual(messages[0].content, "Hello")
        XCTAssertEqual(messages[1].content, "Hi there")
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant)
    }

    // MARK: - Memory scope tests (v2.1)

    func testSaveAndFetchGlobalMemory() throws {
        let memory = GlobalMemory(
            content: "## Identity\n- Alex is a solo founder.\n",
            updatedAt: Date(timeIntervalSince1970: 1234)
        )
        try store.saveGlobalMemory(memory)

        let fetched = try store.fetchGlobalMemory()
        XCTAssertEqual(fetched?.content, memory.content)
        XCTAssertEqual(fetched?.updatedAt.timeIntervalSince1970, 1234)
    }

    func testSaveAndFetchProjectMemory() throws {
        let project = Project(title: "P")
        try store.insertProject(project)

        let memory = ProjectMemory(projectId: project.id, content: "- project thing", updatedAt: Date())
        try store.saveProjectMemory(memory)

        let fetched = try store.fetchProjectMemory(projectId: project.id)
        XCTAssertEqual(fetched?.projectId, project.id)
        XCTAssertEqual(fetched?.content, "- project thing")
    }

    func testProjectMemoryCascadeOnProjectDelete() throws {
        let project = Project(title: "P")
        try store.insertProject(project)
        try store.saveProjectMemory(
            ProjectMemory(projectId: project.id, content: "keep me", updatedAt: Date())
        )

        XCTAssertNotNil(try store.fetchProjectMemory(projectId: project.id))

        try store.deleteProject(id: project.id)

        XCTAssertNil(try store.fetchProjectMemory(projectId: project.id),
                     "Deleting project must cascade-delete its project_memory row")
    }

    func testSaveAndFetchConversationMemory() throws {
        let node = makeNode(type: .conversation)
        try store.insertNode(node)

        let memory = ConversationMemory(nodeId: node.id, content: "- chat gist", updatedAt: Date())
        try store.saveConversationMemory(memory)

        let fetched = try store.fetchConversationMemory(nodeId: node.id)
        XCTAssertEqual(fetched?.nodeId, node.id)
        XCTAssertEqual(fetched?.content, "- chat gist")
    }

    func testConversationMemoryCascadeOnNodeDelete() throws {
        let node = makeNode(type: .conversation)
        try store.insertNode(node)
        try store.saveConversationMemory(
            ConversationMemory(nodeId: node.id, content: "keep me", updatedAt: Date())
        )

        XCTAssertNotNil(try store.fetchConversationMemory(nodeId: node.id))

        try store.deleteNode(id: node.id)

        XCTAssertNil(try store.fetchConversationMemory(nodeId: node.id),
                     "Deleting node must cascade-delete its conversation_memory row")
    }

    func testDeleteNodeRemovesCanonicalConversationMemoryRows() throws {
        let node = makeNode(type: .conversation)
        try store.insertNode(node)

        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: node.id,
                kind: .thread,
                stability: .temporary,
                content: "- active summary",
                sourceNodeIds: [node.id]
            )
        )
        try store.insertMemoryFactEntry(
            MemoryFactEntry(
                scope: .conversation,
                scopeRefId: node.id,
                kind: .decision,
                content: "- fact sidecar",
                stability: .temporary,
                sourceNodeIds: [node.id]
            )
        )

        try store.deleteNode(id: node.id)

        let remainingEntries = try store.fetchMemoryEntries()
            .filter { $0.scope == .conversation && $0.scopeRefId == node.id }
        let remainingFacts = try store.fetchMemoryFactEntries()
            .filter { $0.scope == .conversation && $0.scopeRefId == node.id }
        XCTAssertTrue(remainingEntries.isEmpty)
        XCTAssertTrue(remainingFacts.isEmpty)
    }

    func testDeleteProjectRemovesCanonicalProjectMemoryRows() throws {
        let project = Project(title: "Scoped memory")
        try store.insertProject(project)

        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .project,
                scopeRefId: project.id,
                kind: .thread,
                stability: .temporary,
                content: "- project summary"
            )
        )
        try store.insertMemoryFactEntry(
            MemoryFactEntry(
                scope: .project,
                scopeRefId: project.id,
                kind: .constraint,
                content: "- project constraint",
                stability: .stable
            )
        )

        try store.deleteProject(id: project.id)

        let remainingEntries = try store.fetchMemoryEntries()
            .filter { $0.scope == .project && $0.scopeRefId == project.id }
        let remainingFacts = try store.fetchMemoryFactEntries()
            .filter { $0.scope == .project && $0.scopeRefId == project.id }
        XCTAssertTrue(remainingEntries.isEmpty)
        XCTAssertTrue(remainingFacts.isEmpty)
    }

    /// P1 fix from post-commit /plan-eng-review Codex round: the previous
    /// row-counting approach broke for single-active-chat projects. Because
    /// `saveConversationMemory` uses INSERT OR REPLACE, a project with ONE
    /// hot chat that refreshes 10 times stays at COUNT(rows)=1 forever and
    /// never rolls up. The counter table stores EVENTS, not rows — each
    /// successful conversation refresh bumps it via UPSERT. Project refresh
    /// resets it. The signal still lives in SQLite so it survives app quit.
    func testProjectRefreshCounterTracksEventsNotRows() throws {
        let project = Project(title: "Single-hot-chat project")
        try store.insertProject(project)

        let chat = makeNode(type: .conversation, projectId: project.id)
        try store.insertNode(chat)

        XCTAssertEqual(
            try store.readProjectRefreshCounter(projectId: project.id), 0,
            "no refreshes yet → 0"
        )

        // Refresh the SAME chat 3 times (this is the case the row-counting
        // version got wrong — INSERT OR REPLACE kept the row count at 1).
        try store.incrementProjectRefreshCounter(projectId: project.id)
        try store.incrementProjectRefreshCounter(projectId: project.id)
        try store.incrementProjectRefreshCounter(projectId: project.id)

        XCTAssertEqual(
            try store.readProjectRefreshCounter(projectId: project.id), 3,
            "3 events on a single chat — threshold must fire"
        )

        // Project rollup → counter resets to 0.
        try store.resetProjectRefreshCounter(projectId: project.id)
        XCTAssertEqual(
            try store.readProjectRefreshCounter(projectId: project.id), 0,
            "rollup resets the counter"
        )

        // Further refreshes start counting from zero again.
        try store.incrementProjectRefreshCounter(projectId: project.id)
        XCTAssertEqual(try store.readProjectRefreshCounter(projectId: project.id), 1)
    }

    /// Cross-project contamination guard — bumping project A's counter must
    /// not touch project B's.
    func testProjectRefreshCounterScopedToProject() throws {
        let projectA = Project(title: "A")
        let projectB = Project(title: "B")
        try store.insertProject(projectA)
        try store.insertProject(projectB)

        try store.incrementProjectRefreshCounter(projectId: projectA.id)
        try store.incrementProjectRefreshCounter(projectId: projectA.id)
        try store.incrementProjectRefreshCounter(projectId: projectB.id)

        XCTAssertEqual(try store.readProjectRefreshCounter(projectId: projectA.id), 2)
        XCTAssertEqual(try store.readProjectRefreshCounter(projectId: projectB.id), 1)

        // Reset A doesn't touch B.
        try store.resetProjectRefreshCounter(projectId: projectA.id)
        XCTAssertEqual(try store.readProjectRefreshCounter(projectId: projectA.id), 0)
        XCTAssertEqual(try store.readProjectRefreshCounter(projectId: projectB.id), 1)
    }

    /// Deleting a project must cascade-delete its refresh-state row so a
    /// recycled project UUID can't inherit the predecessor's counter.
    func testProjectRefreshCounterCascadeOnProjectDelete() throws {
        let project = Project(title: "Doomed")
        try store.insertProject(project)
        try store.incrementProjectRefreshCounter(projectId: project.id)
        try store.incrementProjectRefreshCounter(projectId: project.id)
        XCTAssertEqual(try store.readProjectRefreshCounter(projectId: project.id), 2)

        try store.deleteProject(id: project.id)

        XCTAssertEqual(
            try store.readProjectRefreshCounter(projectId: project.id), 0,
            "deleting the project must cascade-delete its refresh-state row"
        )
    }

    // MARK: - Project Tests

    func testInsertAndFetchProject() throws {
        let project = Project(title: "Test Project", goal: "Do something great", emoji: "🚀")
        try store.insertProject(project)

        let fetched = try store.fetchProject(id: project.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, project.id)
        XCTAssertEqual(fetched?.title, "Test Project")
        XCTAssertEqual(fetched?.goal, "Do something great")
        XCTAssertEqual(fetched?.emoji, "🚀")
    }

    func testFetchAllProjects() throws {
        let p1 = Project(title: "Project A")
        let p2 = Project(title: "Project B")
        try store.insertProject(p1)
        try store.insertProject(p2)

        let all = try store.fetchAllProjects()
        XCTAssertEqual(all.count, 2)
    }

    func testDeleteProjectNullsNodeProjectId() throws {
        let project = Project(title: "Will Be Deleted")
        try store.insertProject(project)

        let node = makeNode(title: "Child Node", projectId: project.id)
        try store.insertNode(node)

        // Verify the node has the projectId set
        let before = try store.fetchNode(id: node.id)
        XCTAssertEqual(before?.projectId, project.id)

        // Delete project — should SET NULL on node.projectId via FK
        try store.deleteProject(id: project.id)

        let after = try store.fetchNode(id: node.id)
        XCTAssertNotNil(after, "Node should still exist after project deletion")
        XCTAssertNil(after?.projectId, "Node.projectId should be nil after project deletion")
    }

    // MARK: - Edge Tests

    func testInsertAndFetchEdges() throws {
        let nodeA = makeNode(title: "A")
        let nodeB = makeNode(title: "B")
        try store.insertNode(nodeA)
        try store.insertNode(nodeB)

        let edge = NodeEdge(sourceId: nodeA.id, targetId: nodeB.id, strength: 0.9, type: .semantic)
        try store.insertEdge(edge)

        let edgesForA = try store.fetchEdges(nodeId: nodeA.id)
        XCTAssertEqual(edgesForA.count, 1)
        XCTAssertEqual(edgesForA.first?.sourceId, nodeA.id)
        XCTAssertEqual(edgesForA.first?.targetId, nodeB.id)
        XCTAssertEqual(Double(edgesForA.first?.strength ?? 0), 0.9, accuracy: 0.001)

        // fetchEdges also matches targetId
        let edgesForB = try store.fetchEdges(nodeId: nodeB.id)
        XCTAssertEqual(edgesForB.count, 1)
    }

    func testDeleteEdgesForNode() throws {
        let nodeA = makeNode(title: "A")
        let nodeB = makeNode(title: "B")
        try store.insertNode(nodeA)
        try store.insertNode(nodeB)

        let edge = NodeEdge(sourceId: nodeA.id, targetId: nodeB.id, strength: 0.5, type: .semantic)
        try store.insertEdge(edge)

        try store.deleteEdges(nodeId: nodeA.id, type: .semantic)

        let remaining = try store.fetchEdges(nodeId: nodeA.id)
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Memory Entry Reverse Lookup Tests

    func testFetchMemoryEntriesWithSourceNodeId() throws {
        let nodeA = UUID()
        let nodeB = UUID()

        let entry1 = MemoryEntry(
            scope: .global, kind: .preference, stability: .stable,
            content: "E1", sourceNodeIds: [nodeA]
        )
        let entry2 = MemoryEntry(
            scope: .project, scopeRefId: UUID(), kind: .thread, stability: .temporary,
            content: "E2", sourceNodeIds: [nodeA, nodeB]
        )
        let entry3 = MemoryEntry(
            scope: .conversation, scopeRefId: UUID(), kind: .temporaryContext, stability: .temporary,
            content: "E3", sourceNodeIds: [nodeB]
        )
        try store.insertMemoryEntry(entry1)
        try store.insertMemoryEntry(entry2)
        try store.insertMemoryEntry(entry3)

        let hitsA = try store.fetchMemoryEntries(withSourceNodeId: nodeA)
        XCTAssertEqual(Set(hitsA.map(\.id)), Set([entry1.id, entry2.id]))

        let hitsB = try store.fetchMemoryEntries(withSourceNodeId: nodeB)
        XCTAssertEqual(Set(hitsB.map(\.id)), Set([entry2.id, entry3.id]))

        let hitsUnknown = try store.fetchMemoryEntries(withSourceNodeId: UUID())
        XCTAssertTrue(hitsUnknown.isEmpty)
    }

    func testFetchMemoryEntriesWithSourceNodeIdIgnoresNonActive() throws {
        let nodeA = UUID()
        var entry = MemoryEntry(
            scope: .global, kind: .preference, stability: .stable,
            content: "E", sourceNodeIds: [nodeA]
        )
        try store.insertMemoryEntry(entry)
        entry.status = .superseded
        try store.updateMemoryEntry(entry)

        let hits = try store.fetchMemoryEntries(withSourceNodeId: nodeA, activeOnly: true)
        XCTAssertTrue(hits.isEmpty)

        let allHits = try store.fetchMemoryEntries(withSourceNodeId: nodeA, activeOnly: false)
        XCTAssertEqual(allHits.count, 1)
    }
}
