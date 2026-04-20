import AppKit
import SwiftUI

enum MainTab {
    case chat, notes, galaxy, settings
}

private enum AppBootstrapState {
    case ready(AppDependencies)
    case failed(String)
}

private struct AppDependencies {
    let nodeStore: NodeStore
    let vectorStore: VectorStore
    let embeddingService: EmbeddingService
    let localLLM: LocalLLMService
    let graphEngine: GraphEngine
    let userMemoryService: UserMemoryService
    let governanceTelemetry: GovernanceTelemetryStore
    let settingsVM: SettingsViewModel
    let chatVM: ChatViewModel
    let noteVM: NoteViewModel
    let galaxyVM: GalaxyViewModel
}

private enum AppBootstrapError: LocalizedError {
    case applicationSupportDirectoryUnavailable
    case createDirectoryFailed(path: String, underlying: Error)
    case openDatabaseFailed(path: String, underlying: Error)
    case migrationFailed(name: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            return "Could not locate Application Support."
        case .createDirectoryFailed(let path, let underlying):
            return "Could not create Nous data directory at \(path): \(underlying.localizedDescription)"
        case .openDatabaseFailed(let path, let underlying):
            return "Could not open Nous database at \(path): \(underlying.localizedDescription)"
        case .migrationFailed(let name, let underlying):
            return "\(name) failed during launch: \(underlying.localizedDescription)"
        }
    }
}

struct ContentView: View {
    private static let bootstrapLock = NSLock()
    private static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @State private var isSidebarVisible = true
    @State private var selectedTab: MainTab = .chat
    @State private var selectedProjectId: UUID?
    @State private var isSetupComplete = UserDefaults.standard.bool(forKey: "nous.setup.complete")
    @State private var bootstrapState: AppBootstrapState

    init() {
        _bootstrapState = State(initialValue: Self.bootstrap())
    }

    var body: some View {
        switch bootstrapState {
        case .ready(let dependencies):
            if isSetupComplete {
                mainContent(dependencies: dependencies)
            } else {
                SetupView(
                    isSetupComplete: $isSetupComplete,
                    embeddingService: dependencies.embeddingService,
                    settingsVM: dependencies.settingsVM
                )
            }
        case .failed(let message):
            LaunchFailureView(message: message) {
                bootstrapState = Self.bootstrap()
            }
        }
    }

    @ViewBuilder
    private func mainContent(dependencies: AppDependencies) -> some View {
        HStack(spacing: 20) {
            if isSidebarVisible {
                LeftSidebar(
                    nodeStore: dependencies.nodeStore,
                    selectedTab: $selectedTab,
                    selectedProjectId: $selectedProjectId,
                    selectedNodeId: currentSidebarNodeId(dependencies: dependencies),
                    onNodeSelected: { node in navigateToNode(node, dependencies: dependencies) },
                    onNewChat: {
                        dependencies.chatVM.stopGenerating()
                        dependencies.chatVM.currentNode = nil
                        dependencies.chatVM.messages = []
                        dependencies.chatVM.citations = []
                        dependencies.chatVM.currentResponse = ""
                        dependencies.chatVM.inputText = ""
                        selectedTab = .chat
                    }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            ZStack {
                switch selectedTab {
                case .chat:
                    ChatArea(vm: dependencies.chatVM, isSidebarVisible: $isSidebarVisible)
                case .notes:
                    NoteEditor(
                        vm: dependencies.noteVM,
                        onNavigateToNode: { node in navigateToNode(node, dependencies: dependencies) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColor.colaBeige)
                    .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                case .galaxy:
                    GalaxyView(
                        vm: dependencies.galaxyVM,
                        onNodeSelected: { node in navigateToNode(node, dependencies: dependencies) }
                    )
                case .settings:
                    SettingsView(
                        vm: dependencies.settingsVM,
                        userMemoryService: dependencies.userMemoryService,
                        telemetry: dependencies.governanceTelemetry
                    )
                }
            }
        }
        .frame(width: 800, height: 600)
        .background(.clear)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSidebarVisible)
        .task {
            dependencies.chatVM.defaultProjectId = selectedProjectId
            if !Self.isRunningUnitTests {
                await dependencies.settingsVM.loadEmbeddingModel()
            }
        }
        .onChange(of: selectedProjectId) { _, newValue in
            dependencies.chatVM.defaultProjectId = newValue
        }
    }

    private func currentSidebarNodeId(dependencies: AppDependencies) -> UUID? {
        switch selectedTab {
        case .chat:
            return dependencies.chatVM.currentNode?.id
        case .notes:
            return dependencies.noteVM.currentNote?.id
        case .galaxy, .settings:
            return nil
        }
    }

    private func navigateToNode(_ node: NousNode, dependencies: AppDependencies) {
        switch node.type {
        case .conversation:
            dependencies.chatVM.loadConversation(node)
            selectedTab = .chat
        case .note:
            dependencies.noteVM.openNote(node)
            selectedTab = .notes
        }
    }

    private static func bootstrap() -> AppBootstrapState {
        do {
            return .ready(try makeDependencies())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func makeDependencies() throws -> AppDependencies {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }

        let dbPath = try databasePath()
        let nodeStore: NodeStore
        do {
            nodeStore = try NodeStore(path: dbPath)
        } catch {
            throw AppBootstrapError.openDatabaseFailed(path: dbPath, underlying: error)
        }

        do {
            try MemoryV2Migrator.runIfNeeded(db: nodeStore.rawDatabase)
        } catch {
            throw AppBootstrapError.migrationFailed(name: "MemoryV2Migrator", underlying: error)
        }

        do {
            try MemoryEntriesMigrator.runIfNeeded(store: nodeStore)
        } catch {
            throw AppBootstrapError.migrationFailed(name: "MemoryEntriesMigrator", underlying: error)
        }

        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let localLLM = LocalLLMService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let settingsVM = SettingsViewModel(
            embeddingService: embeddingService,
            localLLM: localLLM,
            nodeStore: nodeStore
        )
        let governanceTelemetry = GovernanceTelemetryStore(nodeStore: nodeStore)
        let userMemoryService = UserMemoryService(
            nodeStore: nodeStore,
            llmServiceProvider: { settingsVM.makeLLMService() },
            governanceTelemetry: governanceTelemetry
        )
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let chatVM = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { settingsVM.makeLLMService() },
            currentProviderProvider: { settingsVM.selectedProvider },
            judgeLLMServiceFactory: { settingsVM.makeJudgeLLMService() },
            governanceTelemetry: governanceTelemetry
        )
        let noteVM = NoteViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine
        )
        let galaxyVM = GalaxyViewModel(nodeStore: nodeStore, graphEngine: graphEngine)

        return AppDependencies(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            localLLM: localLLM,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            governanceTelemetry: governanceTelemetry,
            settingsVM: settingsVM,
            chatVM: chatVM,
            noteVM: noteVM,
            galaxyVM: galaxyVM
        )
    }

    private static func databasePath() throws -> String {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else {
            throw AppBootstrapError.applicationSupportDirectoryUnavailable
        }

        let nousDir = appSupport.appendingPathComponent("Nous", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: nousDir, withIntermediateDirectories: true)
        } catch {
            throw AppBootstrapError.createDirectoryFailed(path: nousDir.path, underlying: error)
        }
        return nousDir.appendingPathComponent("nous.db").path
    }
}

private struct LaunchFailureView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Nous couldn't open its data store.")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(AppColor.colaDarkText)

            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(AppColor.colaDarkText.opacity(0.75))
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Button("Retry") { onRetry() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColor.colaOrange)

                Button("Quit Nous") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(32)
        .background(AppColor.colaBeige)
    }
}
