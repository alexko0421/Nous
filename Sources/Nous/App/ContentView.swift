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
    @State private var selectedSettingsSection: SettingsSection = .profile
    @State private var selectedProjectId: UUID?
    @State private var voiceAttachmentResetToken = UUID()
    @State private var isSetupComplete = UserDefaults.standard.bool(forKey: "nous.setup.complete")
    @AppStorage("nous.appearance") private var appearanceMode = "system"

    private var preferredScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some View {
        Group {
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
        .preferredColorScheme(preferredScheme)
    }

    @ViewBuilder
    private func mainContent(dependencies: AppDependencies) -> some View {
        mainLayout(dependencies: dependencies)
            .frame(minWidth: 800, minHeight: 600)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(AppColor.colaBeige.opacity(0.72))
                    .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
            )
            .background(.clear)
            .overlay(alignment: .bottom) {
                globalVoicePill(dependencies: dependencies)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isSidebarVisible)
            .task {
                configureVoiceHandlers(dependencies: dependencies)
                dependencies.chatVM.defaultProjectId = selectedProjectId
                handleFinderSyncPreferenceChange(dependencies: dependencies, isEnabled: dependencies.settingsVM.finderSyncEnabled)
                if !Self.isRunningUnitTests {
                    await dependencies.settingsVM.loadEmbeddingModel()
                }
                runBackgroundMaintenanceIfEnabled(dependencies: dependencies)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .nousNodesDidChange,
                    object: dependencies.nodeStore
                )
            ) { _ in
                guard dependencies.settingsVM.finderSyncEnabled else { return }
                dependencies.finderProjectSync.scheduleSync()
            }
            .onChange(of: dependencies.settingsVM.finderSyncEnabled) { _, enabled in
                handleFinderSyncPreferenceChange(dependencies: dependencies, isEnabled: enabled)
            }
            .onChange(of: dependencies.settingsVM.assistantThinkingEnabled) { _, enabled in
                guard !enabled else { return }
                dependencies.chatVM.purgePersistedThinkingFromLoadedMessages()
                if dependencies.settingsVM.finderSyncEnabled {
                    dependencies.finderProjectSync.scheduleSync()
                }
            }
            .onChange(of: dependencies.settingsVM.geminiHistoryCacheEnabled) { _, enabled in
                guard !enabled else { return }
                Task {
                    await dependencies.chatVM.purgeGeminiHistoryCaches()
                }
            }
            .onChange(of: dependencies.settingsVM.backgroundAnalysisEnabled) { _, enabled in
                guard enabled else { return }
                runBackgroundMaintenanceIfEnabled(dependencies: dependencies)
            }
            .onChange(of: selectedProjectId) { _, newValue in
                dependencies.chatVM.defaultProjectId = newValue
            }
    }

    @ViewBuilder
    private func mainLayout(dependencies: AppDependencies) -> some View {
        HStack(spacing: 12) {
            if isSidebarVisible && selectedTab != .settings {
                sidebar(dependencies: dependencies)
            }

            selectedContent(dependencies: dependencies)

            if isScratchPadVisible && selectedTab == .chat {
                scratchPad(dependencies: dependencies)
            }
        }
    }

    private func sidebar(dependencies: AppDependencies) -> some View {
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
                dependencies.scratchPadStore.activate(conversationId: nil)
                selectedTab = .chat
            }
        )
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    @ViewBuilder
    private func selectedContent(dependencies: AppDependencies) -> some View {
        ZStack {
            switch selectedTab {
            case .chat:
                ChatArea(
                    vm: dependencies.chatVM,
                    voiceController: dependencies.voiceController,
                    isSidebarVisible: $isSidebarVisible,
                    isScratchPadVisible: $isScratchPadVisible,
                    voiceUnavailableReason: dependencies.settingsVM.voiceModeUnavailableReason,
                    voiceAttachmentResetToken: voiceAttachmentResetToken,
                    onToggleVoiceMode: {
                        toggleVoiceMode(dependencies: dependencies)
                    },
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
                    selectedTab: $selectedSettingsSection,
                    skillStore: dependencies.skillStore,
                    userMemoryService: dependencies.userMemoryService,
                    telemetry: dependencies.governanceTelemetry,
                    galaxyRelationTelemetry: dependencies.galaxyRelationTelemetry,
                    onBack: { selectedTab = .chat }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppColor.colaBeige)
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            }
        }
    }

    private func scratchPad(dependencies: AppDependencies) -> some View {
        ScratchPadPanel(
            isVisible: $isScratchPadVisible,
            store: dependencies.scratchPadStore
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
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

    private func navigateWithVoice(to target: VoiceNavigationTarget) {
        switch target {
        case .chat:
            selectedTab = .chat
        case .notes:
            selectedTab = .notes
        case .galaxy:
            selectedTab = .galaxy
        case .settings:
            selectedTab = .settings
        }
    }

    private func configureVoiceHandlers(dependencies: AppDependencies) {
        dependencies.voiceController.setMemoryContextProvider {
            guard let conversationId = dependencies.chatVM.currentNode?.id else { return nil }
            return VoiceMemoryContext(
                projectId: dependencies.chatVM.currentNode?.projectId ?? dependencies.chatVM.defaultProjectId,
                conversationId: conversationId
            )
        }

        dependencies.voiceController.configure(
            VoiceActionHandlers(
                navigate: { target in
                    navigateWithVoice(to: target)
                },
                setSidebarVisible: { isSidebarVisible = $0 },
                setScratchPadVisible: { visible in
                    isScratchPadVisible = visible
                    if visible {
                        selectedTab = .chat
                    }
                },
                setComposerText: { text in
                    dependencies.chatVM.inputText = text
                    selectedTab = .chat
                },
                appendComposerText: { text in
                    if dependencies.chatVM.inputText.isEmpty {
                        dependencies.chatVM.inputText = text
                    } else {
                        dependencies.chatVM.inputText += "\n" + text
                    }
                    selectedTab = .chat
                },
                clearComposer: {
                    dependencies.chatVM.inputText = ""
                },
                startNewChat: {
                    dependencies.chatVM.stopGenerating()
                    dependencies.chatVM.currentNode = nil
                    dependencies.chatVM.messages = []
                    dependencies.chatVM.citations = []
                    dependencies.chatVM.currentResponse = ""
                    dependencies.chatVM.inputText = ""
                    dependencies.scratchPadStore.activate(conversationId: nil)
                    isScratchPadVisible = false
                    selectedTab = .chat
                    voiceAttachmentResetToken = UUID()
                },
                sendMessage: { text in
                    dependencies.chatVM.inputText = text
                    selectedTab = .chat
                    voiceAttachmentResetToken = UUID()
                    Task {
                        await dependencies.chatVM.send(attachments: [])
                    }
                },
                createNote: { title, body in
                    createVoiceNote(title: title, body: body, dependencies: dependencies)
                },
                setAppearanceMode: { mode in
                    appearanceMode = mode.rawValue
                },
                openSettingsSection: { section in
                    selectedSettingsSection = settingsSection(for: section)
                    selectedTab = .settings
                },
                appSnapshot: {
                    voiceAppSnapshot(dependencies: dependencies)
                }
            )
        )
    }

    private func toggleVoiceMode(dependencies: AppDependencies) {
        configureVoiceHandlers(dependencies: dependencies)

        switch VoiceModeTogglePolicy.action(
            isActive: dependencies.voiceController.isActive,
            isVoiceModeAvailable: dependencies.settingsVM.isVoiceModeAvailable,
            apiKey: dependencies.settingsVM.openaiApiKey
        ) {
        case .stop:
            dependencies.voiceController.stop()

        case .unavailable(let message):
            dependencies.voiceController.status = .error(message)

        case .start(let apiKey):
            Task {
                try? await dependencies.voiceController.start(apiKey: apiKey)
            }
        }
    }

    private func settingsSection(for section: VoiceSettingsSection) -> SettingsSection {
        switch section {
        case .profile: return .profile
        case .general: return .general
        case .models: return .models
        case .memory: return .memory
        }
    }

    private func voiceAppSnapshot(dependencies: AppDependencies) -> VoiceAppSnapshot {
        let projectId = dependencies.chatVM.currentNode?.projectId
            ?? selectedProjectId
            ?? dependencies.chatVM.defaultProjectId
        let projectName = projectId.flatMap { id in
            (try? dependencies.nodeStore.fetchProject(id: id))?.title
        }

        return VoiceAppSnapshot(
            currentTab: voiceNavigationTarget(for: selectedTab),
            settingsSection: selectedTab == .settings ? voiceSettingsSection(for: selectedSettingsSection) : nil,
            composerText: dependencies.chatVM.inputText,
            selectedProjectName: projectName,
            sidebarVisible: isSidebarVisible,
            scratchpadVisible: isScratchPadVisible,
            activeConversationTitle: dependencies.chatVM.currentNode?.title
        )
    }

    private func voiceNavigationTarget(for tab: MainTab) -> VoiceNavigationTarget {
        switch tab {
        case .chat: return .chat
        case .notes: return .notes
        case .galaxy: return .galaxy
        case .settings: return .settings
        }
    }

    private func voiceSettingsSection(for section: SettingsSection) -> VoiceSettingsSection {
        switch section {
        case .profile: return .profile
        case .general: return .general
        case .models: return .models
        case .memory: return .memory
        }
    }

    private func createVoiceNote(title: String, body: String, dependencies: AppDependencies) {
        do {
            try dependencies.noteVM.createNote(title: title, content: body, projectId: selectedProjectId)
            selectedTab = .notes
        } catch {
            dependencies.voiceController.status = .error("Could not create note")
        }
    }

    @ViewBuilder
    private func globalVoicePill(dependencies: AppDependencies) -> some View {
        if selectedTab != .chat {
            HStack(spacing: 8) {
                if dependencies.voiceController.status.shouldDisplayPill || dependencies.voiceController.pendingAction != nil {
                    VoiceCapsuleView(
                        status: dependencies.voiceController.status,
                        subtitleText: dependencies.voiceController.subtitleText,
                        audioLevel: dependencies.voiceController.audioLevel,
                        hasPendingConfirmation: dependencies.voiceController.pendingAction != nil,
                        onConfirm: dependencies.voiceController.confirmPendingAction,
                        onCancel: dependencies.voiceController.cancelPendingAction
                    )
                    VoiceTranscriptPanel(
                        lines: dependencies.voiceController.transcript,
                        isVisible: dependencies.voiceController.isActive
                    )
                    .padding(.top, 60)
                    .allowsHitTesting(true)
                }

                VoiceModeButton(
                    isActive: dependencies.voiceController.isActive,
                    unavailableReason: dependencies.settingsVM.voiceModeUnavailableReason
                ) {
                    toggleVoiceMode(dependencies: dependencies)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func handleFinderSyncPreferenceChange(dependencies: AppDependencies, isEnabled: Bool) {
        if isEnabled {
            dependencies.finderProjectSync.scheduleSync()
        } else {
            dependencies.finderProjectSync.removeExports()
        }
    }

    private func runBackgroundMaintenanceIfEnabled(dependencies: AppDependencies) {
        guard dependencies.settingsVM.backgroundAnalysisEnabled else { return }
        guard !Self.isRunningUnitTests else { return }

        Task {
            await dependencies.conversationTitleBackfill.runIfNeeded()
        }

        Task {
            _ = await dependencies.memoryGraphMessageBackfill.runIfNeeded(maxConversations: 4)
        }

        Task.detached(priority: .utility) {
            // Embedding backfill is bounded per launch (default 64 atoms)
            // so a fresh DB doesn't block on running the embedder
            // hundreds of times in one go. Subsequent launches pick up.
            _ = try? dependencies.memoryAtomEmbeddingBackfill.runIfNeeded()
        }

        if let rollover = dependencies.weeklyReflectionRollover {
            Task.detached(priority: .utility) {
                await rollover()
            }
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
