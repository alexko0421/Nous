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

    /// Codex #4: the evidence-filtered recent feed returns only chats that
    /// have a non-empty conversation_memory row, and returns the memory
    /// content (Alex-only, post-extractor) rather than node.content (raw
    /// transcript with "Alex:"/"Nous:" markers).
    func testFetchRecentConversationMemoriesUsesConversationMemoryNotTranscript() throws {
        let chatWithMemory = makeNode(
            title: "Chat with memory",
            type: .conversation,
            content: "Alex: hi\n\nNous: hi there, raw transcript leaks should not survive"
        )
        try store.insertNode(chatWithMemory)
        try store.saveConversationMemory(
            ConversationMemory(
                nodeId: chatWithMemory.id,
                content: "- Alex wants Nous to remember evidence-only notes",
                updatedAt: Date(timeIntervalSince1970: 1000)
            )
        )

        // A chat with no conversation_memory yet — must be excluded.
        let chatWithoutMemory = makeNode(
            title: "No memory yet",
            type: .conversation,
            content: "Alex: test\n\nNous: reply"
        )
        try store.insertNode(chatWithoutMemory)

        let recents = try store.fetchRecentConversationMemories(limit: 5)

        XCTAssertEqual(recents.count, 1, "chat without conversation_memory must be skipped")
        XCTAssertEqual(recents.first?.title, "Chat with memory")
        XCTAssertEqual(recents.first?.memory,
                       "- Alex wants Nous to remember evidence-only notes")
        XCTAssertFalse(recents.first?.memory.contains("Nous:") ?? true,
                       "raw assistant marker must not reach the recent feed")
    }

    func testFetchRecentConversationMemoriesExcludesCurrentNode() throws {
        let older = makeNode(title: "Older", type: .conversation)
        try store.insertNode(older)
        try store.saveConversationMemory(
            ConversationMemory(nodeId: older.id, content: "- older memory",
                               updatedAt: Date(timeIntervalSince1970: 100))
        )

        let current = makeNode(title: "Current", type: .conversation)
        try store.insertNode(current)
        try store.saveConversationMemory(
            ConversationMemory(nodeId: current.id, content: "- current memory",
                               updatedAt: Date(timeIntervalSince1970: 200))
        )

        let recents = try store.fetchRecentConversationMemories(limit: 5, excludingId: current.id)
        XCTAssertEqual(recents.count, 1)
        XCTAssertEqual(recents.first?.title, "Older")
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
}
