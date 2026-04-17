import SwiftUI

enum MainTab {
    case chat, notes, galaxy, settings
}

struct ContentView: View {
    @State private var isSidebarVisible = true
    @State private var selectedTab: MainTab = .chat
    @State private var selectedProjectId: UUID?
    @State private var isSetupComplete = UserDefaults.standard.bool(forKey: "nous.setup.complete")

    // Services
    @State private var nodeStore: NodeStore
    @State private var vectorStore: VectorStore
    @State private var embeddingService = EmbeddingService()
    @State private var localLLM = LocalLLMService()
    @State private var graphEngine: GraphEngine
    @State private var userMemoryService: UserMemoryService
    @State private var settingsVM: SettingsViewModel
    @State private var chatVM: ChatViewModel
    @State private var noteVM: NoteViewModel
    @State private var galaxyVM: GalaxyViewModel

    init() {
        let dbPath = Self.databasePath()
        let ns = try! NodeStore(path: dbPath)

        // One-time migration from pre-v2.1 user_memory blob. No-op if already done.
        // Idempotent: guarded by schema_meta.memory_version.
        do {
            try MemoryV2Migrator.runIfNeeded(db: ns.rawDatabase)
        } catch {
            print("[Nous] MemoryV2Migrator failed: \(error)")
        }

        let vs = VectorStore(nodeStore: ns)
        let es = EmbeddingService()
        let llm = LocalLLMService()
        let ge = GraphEngine(nodeStore: ns, vectorStore: vs)
        let svm = SettingsViewModel(embeddingService: es, localLLM: llm, nodeStore: ns)
        let ums = UserMemoryService(nodeStore: ns, llmServiceProvider: { svm.makeLLMService() })
        let scheduler = UserMemoryScheduler(service: ums)

        _nodeStore = State(initialValue: ns)
        _vectorStore = State(initialValue: vs)
        _embeddingService = State(initialValue: es)
        _localLLM = State(initialValue: llm)
        _graphEngine = State(initialValue: ge)
        _userMemoryService = State(initialValue: ums)
        _settingsVM = State(initialValue: svm)
        _chatVM = State(initialValue: ChatViewModel(
            nodeStore: ns, vectorStore: vs, embeddingService: es, graphEngine: ge,
            userMemoryService: ums,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { svm.makeLLMService() }
        ))
        _noteVM = State(initialValue: NoteViewModel(nodeStore: ns, vectorStore: vs, embeddingService: es, graphEngine: ge))
        _galaxyVM = State(initialValue: GalaxyViewModel(nodeStore: ns, graphEngine: ge))
    }

    var body: some View {
        if isSetupComplete {
            mainContent
        } else {
            SetupView(
                isSetupComplete: $isSetupComplete,
                embeddingService: embeddingService,
                settingsVM: settingsVM
            )
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        HStack(spacing: 20) {
            if isSidebarVisible {
                LeftSidebar(
                    nodeStore: nodeStore,
                    selectedTab: $selectedTab,
                    selectedProjectId: $selectedProjectId,
                    selectedNodeId: currentSidebarNodeId,
                    onNodeSelected: { node in navigateToNode(node) },
                    onNewChat: {
                        chatVM.currentNode = nil
                        chatVM.messages = []
                        chatVM.citations = []
                        chatVM.currentResponse = ""
                        chatVM.inputText = ""
                        selectedTab = .chat
                    }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            ZStack {
                switch selectedTab {
                case .chat:
                    ChatArea(vm: chatVM, isSidebarVisible: $isSidebarVisible)
                case .notes:
                    NoteEditor(vm: noteVM, onNavigateToNode: { node in navigateToNode(node) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppColor.colaBeige)
                        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                case .galaxy:
                    GalaxyView(vm: galaxyVM, onNodeSelected: { node in navigateToNode(node) })
                case .settings:
                    SettingsView(vm: settingsVM)
                }

                // Tab navigation is handled via sidebar icons (Galaxy, Project)
                // No floating tab bar needed
            }
        }
        .frame(width: 800, height: 600)
        .background(.clear)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSidebarVisible)
        .task { await settingsVM.loadEmbeddingModel() }
    }

    private var currentSidebarNodeId: UUID? {
        switch selectedTab {
        case .chat:
            return chatVM.currentNode?.id
        case .notes:
            return noteVM.currentNote?.id
        case .galaxy, .settings:
            return nil
        }
    }

    private func tabButton(_ title: String, tab: MainTab) -> some View {
        Button(action: { selectedTab = tab }) {
            Text(title)
                .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                .foregroundColor(selectedTab == tab ? AppColor.colaOrange : AppColor.colaDarkText.opacity(0.5))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(selectedTab == tab ? AppColor.colaOrange.opacity(0.12) : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func navigateToNode(_ node: NousNode) {
        switch node.type {
        case .conversation:
            chatVM.loadConversation(node)
            selectedTab = .chat
        case .note:
            noteVM.openNote(node)
            selectedTab = .notes
        }
    }

    private static func databasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let nousDir = appSupport.appendingPathComponent("Nous", isDirectory: true)
        try? FileManager.default.createDirectory(at: nousDir, withIntermediateDirectories: true)
        return nousDir.appendingPathComponent("nous.db").path
    }
}
