import AppKit
import SwiftUI

enum MainTab {
    case chat, notes, galaxy, settings
}

struct ContentView: View {
    let env: AppEnvironment
    private static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @State private var isSidebarVisible = true
    @State private var isScratchPadVisible = false
    @State private var selectedTab: MainTab = .chat
    @State private var selectedProjectId: UUID?
    @State private var isSetupComplete = UserDefaults.standard.bool(forKey: "nous.setup.complete")

    var body: some View {
        switch env.state {
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
                env.state = AppEnvironment.bootstrap()
            }
        case .initializing:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppColor.colaBeige)
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
                    ChatArea(
                        vm: dependencies.chatVM,
                        isSidebarVisible: $isSidebarVisible,
                        onNavigateToNode: { node in navigateToNode(node, dependencies: dependencies) }
                    )
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColor.colaBeige)
                    .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                }
            }

            if isScratchPadVisible && selectedTab == .chat {
                ScratchPadPanel(
                    isVisible: $isScratchPadVisible,
                    store: dependencies.scratchPadStore
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(AppColor.colaBeige.opacity(0.72))
                .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
        )
        .background(.clear)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSidebarVisible)
        .task {
            dependencies.chatVM.defaultProjectId = selectedProjectId
            dependencies.finderProjectSync.scheduleSync()
            if !Self.isRunningUnitTests {
                await dependencies.settingsVM.loadEmbeddingModel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nousNodesDidChange)) { _ in
            dependencies.finderProjectSync.scheduleSync()
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
