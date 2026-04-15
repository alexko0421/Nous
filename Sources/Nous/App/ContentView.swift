import SwiftUI

enum MainTab {
    case chat, notes, galaxy
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

    init(settingsVM: SettingsViewModel, nodeStore: NodeStore, embeddingService: EmbeddingService, localLLM: LocalLLMService) {
        let vs = VectorStore(nodeStore: nodeStore)
        let ge = GraphEngine(nodeStore: nodeStore, vectorStore: vs)

        _settingsVM = State(initialValue: settingsVM)
        _nodeStore = State(initialValue: nodeStore)
        _embeddingService = State(initialValue: embeddingService)
        _localLLM = State(initialValue: localLLM)
        _vectorStore = State(initialValue: vs)
        _graphEngine = State(initialValue: ge)
        _chatVM = State(initialValue: ChatViewModel(
            nodeStore: nodeStore, vectorStore: vs, embeddingService: embeddingService, graphEngine: ge,
            llmServiceProvider: { settingsVM.makeLLMService() },
            localLLMProvider: { localLLM.isLoaded ? localLLM : nil },
            fallbackProvider: { settingsVM.makeFallbackServices() }
        ))
        _noteVM = State(initialValue: NoteViewModel(nodeStore: nodeStore, vectorStore: vs, embeddingService: embeddingService, graphEngine: ge))
        _galaxyVM = State(initialValue: GalaxyViewModel(nodeStore: nodeStore, graphEngine: ge))
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
                    settingsVM: settingsVM,
                    selectedTab: $selectedTab,
                    selectedProjectId: $selectedProjectId,
                    selectedNodeId: chatVM.currentNode?.id,
                    onNodeSelected: { node in navigateToNode(node) },
                    onNewChat: {
                        chatVM.resetDraft(projectId: selectedProjectId)
                        selectedTab = .chat
                    }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            ZStack {
                switch selectedTab {
                case .chat:
                    ChatArea(vm: chatVM, settingsVM: settingsVM, isSidebarVisible: $isSidebarVisible)
                case .notes:
                    NoteEditor(vm: noteVM, onNavigateToNode: { node in navigateToNode(node) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppColor.colaBeige)
                        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                case .galaxy:
                    GalaxyView(vm: galaxyVM, onNodeSelected: { node in navigateToNode(node) })
                }

                // Tab navigation is handled via sidebar icons (Galaxy, Project)
                // No floating tab bar needed
            }
        }
        .frame(minWidth: 600, idealWidth: 800, minHeight: 450, idealHeight: 600)
        .background(.clear)
        .ignoresSafeArea(.all)
        .offset(y: -1) // Submerge the 1px ghost line into the window boundary
        .padding(.bottom, -1) // Correct the overlap at the bottom
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSidebarVisible)
        .task { await settingsVM.loadEmbeddingModel() }
        .onAppear { syncProjectContext(selectedProjectId) }
        .onChange(of: selectedProjectId) { _, newValue in
            syncProjectContext(newValue)
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
        selectedProjectId = node.projectId
        switch node.type {
        case .conversation:
            chatVM.loadConversation(node)
            selectedTab = .chat
        case .note:
            noteVM.openNote(node)
            selectedTab = .notes
        }
    }

    private func syncProjectContext(_ projectId: UUID?) {
        chatVM.activeProjectId = projectId
        noteVM.activeProjectId = projectId
        galaxyVM.filterProjectId = projectId
    }

}
