import XCTest
@testable import Nous

final class ChatViewModelTests: XCTestCase {

    func testChatModeDefaultsToCompanion() throws {
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

        XCTAssertEqual(vm.activeChatMode, .companion)
    }

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

    func testSetChatModeSwitchesToStrategist() throws {
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

        vm.setChatMode(.strategist)

        XCTAssertEqual(vm.activeChatMode, .strategist)
    }

    func testGovernanceTelemetryRecordsPromptTraceWithoutSafetyMissWhenSafetyInvoked() throws {
        let suiteName = "ChatViewModelTests.governance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let telemetry = GovernanceTelemetryStore(defaults: defaults)

        telemetry.recordPromptTrace(
            PromptGovernanceTrace(
                promptLayers: ["anchor", "core_safety_policy", "global_memory", "high_risk_safety_mode"],
                evidenceAttached: false,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: true
            )
        )

        XCTAssertEqual(telemetry.value(for: .memoryUsefulness), 1)
        XCTAssertEqual(telemetry.value(for: .safetyMissRate), 0)
        XCTAssertEqual(telemetry.lastPromptTrace?.safetyPolicyInvoked, true)
    }
}
