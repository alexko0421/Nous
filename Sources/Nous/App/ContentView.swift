import AppKit
import SwiftUI

enum MainTab {
    case chat, notes, galaxy, settings
}

enum GlobalVoicePillPolicy {
    static func shouldShowStartButton(selectedTab: MainTab) -> Bool {
        selectedTab == .notes
    }

    static func canHostCapsule(selectedTab: MainTab) -> Bool {
        selectedTab != .chat && selectedTab != .galaxy
    }
}

private struct MainWindowGlassBackground: View {
    private let cornerRadius: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.clear)
            .background(
                NativeGlassPanel(cornerRadius: cornerRadius, tintColor: AppColor.windowGlassTint) {
                    EmptyView()
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppColor.inkBackground.opacity(0.34))
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.28),
                                Color.white.opacity(0.08),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .blendMode(.screen)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 8)
    }
}

struct ContentView: View {
    let env: AppEnvironment
    private static let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    @State private var isSidebarVisible = true
    @State private var rightPanelMode: RightPanelMode?
    @State private var scratchPadPanelMode: ScratchPadPanelMode = .preview
    @State private var selectedTab: MainTab = .chat
    @State private var selectedSettingsSection: SettingsSection = .profile
    @State private var selectedProjectId: UUID?
    @State private var selectedGalaxyLens: GalaxyLensFilter = .meaningful
    @State private var voiceAttachmentResetToken = UUID()
    @State private var isSetupComplete = UserDefaults.standard.bool(forKey: "nous.setup.complete")
    @State private var voiceFocusObserver = VoiceMainWindowFocusObserver()
    @State private var voiceNotchPanelController: VoiceNotchPanelController?
    @AppStorage("nous.appearance") private var appearanceMode = "system"

    private var preferredScheme: ColorScheme? {
        AppAppearanceMode.preferredColorScheme(for: appearanceMode)
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
        .background(WindowAppearanceBridge(appearanceMode: appearanceMode))
    }

    @ViewBuilder
    private func mainContent(dependencies: AppDependencies) -> some View {
        mainLayout(dependencies: dependencies)
            .frame(
                minWidth: RightPanelLayout.minimumContentWidth,
                minHeight: RightPanelLayout.minimumContentHeight
            )
            .padding(RightPanelLayout.windowPadding)
            .background(
                MainWindowGlassBackground()
            )
            .background(.clear)
            .overlay(alignment: .bottom) {
                globalVoicePill(dependencies: dependencies)
            }
            .animation(AppMotion.sidebarPanelSpring.animation, value: isSidebarVisible)
            .animation(AppMotion.markdownPanelSpring.animation, value: rightPanelMode)
            .onAppear {
                if voiceNotchPanelController == nil {
                    voiceNotchPanelController = VoiceNotchPanelController(
                        voiceController: dependencies.voiceController,
                        focusObserver: voiceFocusObserver
                    )
                }
            }
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
            .onChange(of: selectedTab) { _, newValue in
                let nextMode = RightPanelSurfaceScope.modeAfterTabChange(
                    currentMode: rightPanelMode,
                    selectedTabIsChat: newValue == .chat
                )
                guard nextMode != rightPanelMode else { return }
                withAnimation(AppMotion.markdownPanelSpring.animation) {
                    rightPanelMode = nextMode
                }
            }
    }

    @ViewBuilder
    private func mainLayout(dependencies: AppDependencies) -> some View {
        HStack(spacing: 12) {
            if isSidebarVisible && selectedTab != .settings {
                sidebar(dependencies: dependencies)
            }

            selectedContent(dependencies: dependencies)
                .frame(minWidth: RightPanelLayout.preferredWidth)
                .layoutPriority(1)

            if selectedTab == .chat {
                rightPanel(dependencies: dependencies)
                    .layoutPriority(0)
            }
        }
    }

    private func sidebar(dependencies: AppDependencies) -> some View {
        LeftSidebar(
            nodeStore: dependencies.nodeStore,
            conversationSessionStore: dependencies.conversationSessionStore,
            selectedTab: $selectedTab,
            selectedProjectId: $selectedProjectId,
            selectedNodeId: currentSidebarNodeId(dependencies: dependencies),
            onNodeSelected: { node in navigateToNode(node, dependencies: dependencies) },
            onNewChat: {
                dependencies.chatVM.startBlankConversation()
                let nextMode = RightPanelSurfaceScope.modeAfterNewBlankConversation(currentMode: rightPanelMode)
                if nextMode != rightPanelMode {
                    withAnimation(AppMotion.markdownPanelSpring.animation) {
                        rightPanelMode = nextMode
                    }
                }
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
                    rightPanelMode: $rightPanelMode,
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
                    selectedLens: $selectedGalaxyLens,
                    onNodeSelected: { node in navigateToNode(node, dependencies: dependencies) }
                )
            case .settings:
                SettingsView(
                    vm: dependencies.settingsVM,
                    selectedTab: $selectedSettingsSection,
                    skillStore: dependencies.skillStore,
                    failureSkillCandidateStore: dependencies.failureSkillCandidateStore,
                    failureSkillRepairRunStore: dependencies.failureSkillRepairRunStore,
                    userMemoryService: dependencies.userMemoryService,
                    telemetry: dependencies.governanceTelemetry,
                    galaxyRelationTelemetry: dependencies.galaxyRelationTelemetry,
                    shadowLearningStore: dependencies.shadowLearningStore,
                    beadsAgentWorkVM: dependencies.beadsAgentWorkVM,
                    onBack: { selectedTab = .chat }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppColor.colaBeige)
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .stroke(AppColor.sidebarGlassStroke.opacity(0.26), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func rightPanel(dependencies: AppDependencies) -> some View {
        switch rightPanelMode {
        case .markdown:
            ScratchPadPanel(
                isVisible: scratchPadVisibilityBinding,
                store: dependencies.scratchPadStore,
                mode: $scratchPadPanelMode
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))

        case .youtube:
            YouTubeLearningPanel(
                viewModel: dependencies.youtubeLearningVM,
                currentProjectId: dependencies.chatVM.currentNode?.projectId ?? dependencies.chatVM.defaultProjectId,
                onSelectContext: { context in
                    dependencies.chatVM.activateSourceDiscussion(context)
                    selectedTab = .chat
                },
                onClose: {
                    withAnimation(AppMotion.markdownPanelSpring.animation) {
                        rightPanelMode = nil
                    }
                }
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))

        case .none:
            EmptyView()
        }
    }

    private var scratchPadVisibilityBinding: Binding<Bool> {
        Binding(
            get: { rightPanelMode == .markdown },
            set: { visible in
                if visible {
                    rightPanelMode = .markdown
                } else if rightPanelMode == .markdown {
                    rightPanelMode = nil
                }
            }
        )
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
        case .source:
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
                setSidebarVisible: { visible in
                    withAnimation(AppMotion.sidebarPanelSpring.animation) {
                        isSidebarVisible = visible
                    }
                },
                setScratchPadVisible: { visible in
                    withAnimation(AppMotion.markdownPanelSpring.animation) {
                        if visible {
                            rightPanelMode = .markdown
                            selectedTab = .chat
                        } else if rightPanelMode == .markdown {
                            rightPanelMode = nil
                        }
                    }
                },
                openScratchPadForWriting: {
                    withAnimation(AppMotion.markdownPanelSpring.animation) {
                        rightPanelMode = .markdown
                        scratchPadPanelMode = .write
                        selectedTab = .chat
                    }
                },
                replaceScratchPadMarkdown: { markdown in
                    writeVoiceScratchPadDraft(markdown, mode: .replace, dependencies: dependencies)
                },
                appendScratchPadMarkdown: { markdown in
                    writeVoiceScratchPadDraft(markdown, mode: .append, dependencies: dependencies)
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
                    dependencies.chatVM.startBlankConversation()
                    let nextMode = RightPanelSurfaceScope.modeAfterNewBlankConversation(currentMode: rightPanelMode)
                    withAnimation(AppMotion.markdownPanelSpring.animation) {
                        rightPanelMode = nextMode
                    }
                    selectedTab = .chat
                    voiceAttachmentResetToken = UUID()
                },
                createNote: { title, body in
                    createVoiceNote(title: title, body: body, dependencies: dependencies)
                },
                summarizeYouTubeVideo: { explicitURL in
                    await summarizeYouTubeVideoWithVoice(explicitURL: explicitURL, dependencies: dependencies)
                },
                getActiveSourceContext: {
                    guard let context = dependencies.chatVM.activeSourceDiscussionContext else {
                        return .noActiveSourceContext
                    }
                    return VoiceSourceContextResult(context: context)
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

    private enum VoiceScratchPadWriteMode {
        case replace
        case append
    }

    private func writeVoiceScratchPadDraft(
        _ markdown: String,
        mode: VoiceScratchPadWriteMode,
        dependencies: AppDependencies
    ) {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        withAnimation(AppMotion.markdownPanelSpring.animation) {
            rightPanelMode = .markdown
            scratchPadPanelMode = .write
            selectedTab = .chat
        }

        switch mode {
        case .replace:
            dependencies.scratchPadStore.updateContent(trimmed)
        case .append:
            let current = dependencies.scratchPadStore.currentContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = current.isEmpty ? trimmed : "\(current)\n\n\(trimmed)"
            dependencies.scratchPadStore.updateContent(next)
        }
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
            let conversationId: UUID
            do {
                conversationId = try dependencies.chatVM.ensureConversationForVoice()
            } catch {
                print("[ContentView] ensureConversationForVoice failed: \(error)")
                dependencies.voiceController.status = .error("Could not prepare conversation")
                return
            }

            // CRITICAL: bind BEFORE start() runs. start() invokes markListening()
            // which calls resetTranscript(). resetTranscript() does NOT clear
            // boundConversationId (rev 5 fix), but the order matters: the
            // committer's onUserUtteranceFinalized closure reads
            // boundConversationId at fire time, so it must be set before any
            // utterance arrives.
            dependencies.voiceController.boundConversationId = conversationId

            Task {
                dependencies.voiceController.setConfiguration(
                    RealtimeVoiceConfiguration(
                        voice: dependencies.settingsVM.voiceOutputVoice,
                        language: dependencies.settingsVM.voiceLanguage
                    )
                )
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
        let sourceContext = dependencies.chatVM.activeSourceDiscussionContext

        return VoiceAppSnapshot(
            currentTab: voiceNavigationTarget(for: selectedTab),
            settingsSection: selectedTab == .settings ? voiceSettingsSection(for: selectedSettingsSection) : nil,
            composerText: dependencies.chatVM.inputText,
            selectedProjectName: projectName,
            sidebarVisible: isSidebarVisible,
            scratchpadVisible: rightPanelMode == .markdown,
            scratchpadMarkdown: dependencies.scratchPadStore.currentContent,
            activeConversationTitle: dependencies.chatVM.currentNode?.title,
            rightPanelMode: voiceSnapshotRightPanelMode,
            youtubeURLText: dependencies.youtubeLearningVM.urlText,
            activeSourceTitle: sourceContext?.title,
            activeSourceTimeRange: sourceContext?.timeRangeLabel,
            activeSourceSummaryTitle: sourceContext?.summaryTitle,
            activeSourceEvidenceLevel: sourceContext?.evidenceLabel
        )
    }

    private var voiceSnapshotRightPanelMode: String? {
        switch rightPanelMode {
        case .markdown:
            return "markdown"
        case .youtube:
            return "youtube"
        case .none:
            return nil
        }
    }

    private func summarizeYouTubeVideoWithVoice(
        explicitURL: String?,
        dependencies: AppDependencies
    ) async -> VoiceYouTubeSummaryResult {
        let currentPanelURL = rightPanelMode == .youtube ? dependencies.youtubeLearningVM.urlText : nil

        guard let resolvedURL = VoiceYouTubeURLRequestResolver.resolve(
            explicitURL: explicitURL,
            activeBrowserURL: { dependencies.activeBrowserTabURLReader.currentActiveBrowserURL() },
            currentPanelURL: currentPanelURL,
            clipboardText: { NSPasteboard.general.string(forType: .string) }
        ) else {
            selectedTab = .chat
            withAnimation(AppMotion.markdownPanelSpring.animation) {
                rightPanelMode = .youtube
            }
            return .missingURL
        }

        selectedTab = .chat
        withAnimation(AppMotion.markdownPanelSpring.animation) {
            rightPanelMode = .youtube
        }
        dependencies.youtubeLearningVM.urlText = resolvedURL
        await dependencies.youtubeLearningVM.load(
            projectId: dependencies.chatVM.currentNode?.projectId ?? dependencies.chatVM.defaultProjectId
        )

        if !dependencies.youtubeLearningVM.summarySections.isEmpty {
            return VoiceYouTubeSummaryResult(
                succeeded: true,
                status: "YouTube summary ready",
                output: "Summary ready. Click a section to discuss it."
            )
        }

        let message = dependencies.youtubeLearningVM.errorMessage
            ?? dependencies.youtubeLearningVM.summaryUnavailableMessage
            ?? "YouTube summary unavailable."
        return VoiceYouTubeSummaryResult(
            succeeded: false,
            status: message,
            output: message
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

    private func voiceSettingsSection(for section: SettingsSection) -> VoiceSettingsSection? {
        switch section {
        case .profile: return .profile
        case .general: return .general
        case .models: return .models
        case .memory: return .memory
        case .agentWork: return nil
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
        let shouldShowCapsule = GlobalVoicePillPolicy.canHostCapsule(selectedTab: selectedTab) &&
            VoiceCapsuleVisibilityPolicy.shouldShowCapsule(
                isVoiceActive: dependencies.voiceController.isActive,
                status: dependencies.voiceController.status,
                hasPendingAction: dependencies.voiceController.pendingAction != nil,
                hasSummaryPreview: dependencies.voiceController.summaryPreview != nil
            )
        let shouldShowStartButton = GlobalVoicePillPolicy.shouldShowStartButton(selectedTab: selectedTab)

        if shouldShowCapsule || shouldShowStartButton {
            HStack(spacing: 8) {
                if shouldShowCapsule {
                    VoiceCapsuleView(
                        status: dependencies.voiceController.status,
                        subtitleText: dependencies.voiceController.subtitleText,
                        audioLevel: dependencies.voiceController.audioLevel,
                        hasPendingConfirmation: dependencies.voiceController.pendingAction != nil,
                        summaryPreview: dependencies.voiceController.summaryPreview,
                        onConfirm: dependencies.voiceController.confirmPendingAction,
                        onCancel: dependencies.voiceController.cancelPendingAction,
                        onDismissSummary: dependencies.voiceController.dismissSummaryPreview
                    )
                }

                if shouldShowStartButton {
                    VoiceModeButton(
                        isActive: dependencies.voiceController.isActive,
                        unavailableReason: dependencies.settingsVM.voiceModeUnavailableReason
                    ) {
                        toggleVoiceMode(dependencies: dependencies)
                    }
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

        dependencies.heartbeatCoordinator.scheduleShadowLearningAfterIdle()
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
