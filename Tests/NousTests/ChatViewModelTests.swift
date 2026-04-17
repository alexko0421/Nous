import XCTest
@testable import Nous

final class ChatViewModelTests: XCTestCase {

    func testSendCreatesConversationInsideSelectedProject() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { nil }
        )

        let project = Project(title: "Nous")
        try nodeStore.insertProject(project)

        vm.defaultProjectId = project.id
        vm.inputText = "How should memory entries work?"

        await vm.send()

        XCTAssertEqual(vm.currentNode?.projectId, project.id)
    }

    func testQuickActionConversationUsesSelectedProject() async throws {
        let nodeStore = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let userMemoryService = UserMemoryService(nodeStore: nodeStore, llmServiceProvider: { nil })
        let scheduler = UserMemoryScheduler(service: userMemoryService)

        let vm = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { nil }
        )

        let project = Project(title: "Memory Project")
        try nodeStore.insertProject(project)
        vm.defaultProjectId = project.id

        await vm.beginQuickActionConversation(.direction)

        XCTAssertEqual(vm.currentNode?.projectId, project.id)
    }
}
