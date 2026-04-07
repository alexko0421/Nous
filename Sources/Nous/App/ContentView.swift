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
    @State private var settingsVM: SettingsViewModel
    @State private var chatVM: ChatViewModel
    @State private var noteVM: NoteViewModel
    @State private var galaxyVM: GalaxyViewModel

    init() {
        let dbPath = Self.databasePath()
        let ns = try! NodeStore(path: dbPath)
        let vs = VectorStore(nodeStore: ns)
        let es = EmbeddingService()
        let llm = LocalLLMService()
        let ge = GraphEngine(nodeStore: ns, vectorStore: vs)
        let svm = SettingsViewModel(embeddingService: es, localLLM: llm, nodeStore: ns)

        _nodeStore = State(initialValue: ns)
        _vectorStore = State(initialValue: vs)
        _embeddingService = State(initialValue: es)
        _localLLM = State(initialValue: llm)
        _graphEngine = State(initialValue: ge)
        _settingsVM = State(initialValue: svm)
        _chatVM = State(initialValue: ChatViewModel(
            nodeStore: ns, vectorStore: vs, embeddingService: es, graphEngine: ge,
            llmServiceProvider: { svm.makeLLMService() }
        ))
        _noteVM = State(initialValue: NoteViewModel(nodeStore: ns, vectorStore: vs, embeddingService: es, graphEngine: ge))
        _galaxyVM = State(initialValue: GalaxyViewModel(nodeStore: ns, graphEngine: ge))
    }

    var body: some View {
        // If not set up, show SetupView (Task 13 will create it — for now just show main UI always)
        mainContent
    }

    @ViewBuilder
    private var mainContent: some View {
        HStack(spacing: 20) {
            if isSidebarVisible {
                LeftSidebar(
                    nodeStore: nodeStore,
                    selectedTab: $selectedTab,
                    selectedProjectId: $selectedProjectId,
                    onNodeSelected: { node in navigateToNode(node) }
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

                // Tab bar
                if selectedTab != .settings {
                    VStack {
                        HStack(spacing: 4) {
                            tabButton("Chat", tab: .chat)
                            tabButton("Notes", tab: .notes)
                            tabButton("Galaxy", tab: .galaxy)
                        }
                        .padding(4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        Spacer()
                    }
                    .padding(.top, 12)
                }
            }
        }
        .frame(width: 800, height: 600)
        .background(.clear)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSidebarVisible)
        .task { await settingsVM.loadEmbeddingModel() }
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
