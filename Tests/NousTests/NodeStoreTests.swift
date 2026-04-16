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
