import PhotosUI
import SwiftUI

struct ChatArea: View {
    @Bindable var vm: ChatViewModel
    @Bindable var voiceController: VoiceCommandController
    @Binding var isSidebarVisible: Bool
    @Binding var isScratchPadVisible: Bool
    let voiceUnavailableReason: String?
    let voiceAttachmentResetToken: UUID
    let onToggleVoiceMode: () -> Void
    var onNavigateToNode: (NousNode) -> Void = { _ in }

    @State private var attachments: [AttachedFileContext] = []
    @State private var isRelevantChatsExpanded = false
    @State private var isAttachmentMenuPresented = false
    @State private var isActionMenuExpanded = false
    @State private var isFileImporterPresented = false
    @State private var isPhotosPickerPresented = false
    @State private var isImageDropTargeted = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var floatingHeaderHeight: CGFloat = 76
    @State private var floatingComposerHeight: CGFloat = 124
    @State private var activeDownvotePopoverMessageId: UUID?
    @State private var downvoteFeedbackReason: JudgeFeedbackReason?
    @State private var downvoteFeedbackNote: String = ""
    @FocusState private var isComposerFocused: Bool
    @Namespace private var composerPrimaryActionNamespace

    private let bottomScrollAnchor = "chat-bottom-anchor"
    private let bottomVisibleSpacing: CGFloat = 53
    private let composerMaxWidth: CGFloat = 820
    private let composerActionMotion = ComposerPrimaryActionMotion()
    
    private var isWelcomeState: Bool {
        vm.messages.isEmpty && vm.currentNode == nil
    }

    private var canSend: Bool {
        (
            !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !attachments.isEmpty
        ) && !vm.isGenerating
    }

    private var canPrimaryAction: Bool {
        vm.isGenerating || canSend
    }

    private var shouldSeparateComposerPrimaryAction: Bool {
        ComposerSeparationPolicy.shouldSeparate(
            inputText: vm.inputText,
            hasAttachments: !attachments.isEmpty,
            isGenerating: vm.isGenerating
        )
    }

    private var remainingImageAttachmentSlots: Int {
        AttachmentLimitPolicy.remainingImageSlots(in: attachments)
    }

    private var canPickPhotoAttachment: Bool {
        remainingImageAttachmentSlots > 0
    }

    private var activeClarificationCard: ClarificationCard? {
        if vm.isGenerating, !vm.currentResponse.isEmpty {
            return ClarificationCardParser.parse(vm.currentResponse).card
        }

        guard let lastMessage = vm.messages.last, lastMessage.role == .assistant else {
            return nil
        }

        return ClarificationCardParser.parse(lastMessage.content).card
    }

    private var latestUserMessageId: UUID? {
        vm.messages.last(where: { $0.role == .user })?.id
    }

    private var citationNodeIDs: [UUID] {
        vm.citations.map(\.node.id)
    }

    private var streamingPresentation: StreamingAssistantPresentation {
        StreamingAssistantPresentation(
            isGenerating: vm.isGenerating,
            currentThinking: vm.currentThinking,
            currentThinkingStartedAt: vm.currentThinkingStartedAt,
            currentResponse: vm.currentResponse,
            currentAgentTraceIsEmpty: vm.currentAgentTrace.isEmpty
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if isWelcomeState {
                WelcomeView(
                    inputText: $vm.inputText,
                    attachments: attachments,
                    onPickAttachment: { isFileImporterPresented = true },
                    onPickPhoto: { isPhotosPickerPresented = true },
                    onVoice: { onToggleVoiceMode() },
                    canPickPhoto: canPickPhotoAttachment,
                    isVoiceActive: voiceController.isActive,
                    onRemoveAttachment: removeAttachment,
                    onSend: sendCurrentInput,
                    onImageDrop: handleImageDrop,
                    onQuickActionSelected: { mode in
                        Task {
                            await vm.beginQuickActionConversation(mode)
                        }
                    }
                )
            } else {
                // Full-screen floating layout
                ZStack {
                    // Chat log (underneath overlays)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 28) {
                                ForEach(vm.messages) { msg in
                                    VStack(alignment: .leading, spacing: 4) {
                                        MessageBubble(
                                            text: msg.content,
                                            thinkingContent: msg.thinkingContent,
                                            thinkingStartedAt: nil,
                                            agentTraceRecords: msg.decodedAgentTraceRecords,
                                            isThinkingStreaming: false,
                                            isAgentTraceStreaming: false,
                                            isUser: msg.role == .user,
                                            source: msg.source,
                                            timestamp: msg.timestamp
                                        )
                                        if shouldShowRelevantChats(after: msg) {
                                            RAGCitationView(
                                                citations: vm.citations,
                                                isExpanded: $isRelevantChatsExpanded,
                                                onOpenSource: onNavigateToNode
                                            )
                                            .padding(.top, 8)
                                        }
                                        if msg.role == .assistant {
                                            HStack(spacing: 4) {
                                                if let eventId = vm.judgeEventId(forMessageId: msg.id) {
                                                    let feedback = vm.feedback(forMessageId: msg.id)

                                                    AssistantFeedbackButton(
                                                        symbolName: feedback == .up ? "hand.thumbsup.fill" : "hand.thumbsup",
                                                        isSelected: feedback == .up,
                                                        helpText: feedback == .up
                                                            ? "Clear useful feedback (event \(eventId.uuidString.prefix(8)))"
                                                            : "Mark this reply as useful (event \(eventId.uuidString.prefix(8)))"
                                                    ) {
                                                        handleThumbsUpTap(for: msg.id)
                                                    }

                                                    AssistantFeedbackButton(
                                                        symbolName: feedback == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                                                        isSelected: feedback == .down,
                                                        helpText: feedback == .down
                                                            ? "Clear not useful feedback (event \(eventId.uuidString.prefix(8)))"
                                                            : "Mark this reply as not useful (event \(eventId.uuidString.prefix(8)))"
                                                    ) {
                                                        handleThumbsDownTap(for: msg.id)
                                                    }
                                                    .popover(
                                                        isPresented: isDownvotePopoverPresented(for: msg.id),
                                                        arrowEdge: .bottom
                                                    ) {
                                                        DownvoteFeedbackPopover(
                                                            selectedReason: $downvoteFeedbackReason,
                                                            note: $downvoteFeedbackNote,
                                                            onSave: { saveDownvoteFeedback(for: msg.id) },
                                                            onSkip: closeDownvotePopover
                                                        )
                                                    }
                                                }

                                                if vm.canRegenerateAssistantMessage(msg.id) {
                                                    AssistantFeedbackButton(
                                                        symbolName: "arrow.clockwise",
                                                        isSelected: false,
                                                        helpText: "Regenerate response"
                                                    ) {
                                                        Task {
                                                            await vm.regenerateLatestAssistant()
                                                        }
                                                    }
                                                }

                                                CopyButton(text: msg.content)
                                            }
                                            .font(.footnote)
                                            .foregroundStyle(AppColor.colaDarkText.opacity(0.5))
                                        }
                                    }
                                }
                                if streamingPresentation.showsPendingThinking {
                                    HStack {
                                        ThinkingAccordion(
                                            content: streamingPresentation.pendingThinkingContent,
                                            isStreaming: true,
                                            startedAt: streamingPresentation.pendingThinkingStartedAt
                                        )
                                        Spacer(minLength: 0)
                                    }
                                }
                                if streamingPresentation.showsPendingAgentTrace {
                                    HStack {
                                        AgentTraceAccordion(
                                            records: vm.currentAgentTrace,
                                            isStreaming: true
                                        )
                                        Spacer(minLength: 0)
                                    }
                                }
                                if streamingPresentation.showsAssistantDraft {
                                    VStack(alignment: .leading, spacing: 4) {
                                        MessageBubble(
                                            text: vm.currentResponse,
                                            thinkingContent: streamingPresentation.draftThinkingContent,
                                            thinkingStartedAt: streamingPresentation.draftThinkingStartedAt,
                                            agentTraceRecords: vm.currentAgentTrace,
                                            isThinkingStreaming: streamingPresentation.isDraftThinkingStreaming,
                                            isAgentTraceStreaming: streamingPresentation.isDraftAgentTraceStreaming,
                                            isUser: false,
                                            source: .typed,
                                            timestamp: Date()
                                        )
                                        if !vm.citations.isEmpty {
                                            RAGCitationView(
                                                citations: vm.citations,
                                                isExpanded: $isRelevantChatsExpanded,
                                                onOpenSource: onNavigateToNode
                                            )
                                            .padding(.top, 4)
                                        }
                                    }
                                }
                                Color.clear
                                    .frame(height: floatingComposerHeight + bottomVisibleSpacing)
                                    .id(bottomScrollAnchor)
                            }
                            .padding(.horizontal, 36)
                            .padding(.top, 76)
                            .padding(.bottom, 8)
                        }
                        .onAppear {
                            scrollToBottom(with: proxy)
                        }
                        .onChange(of: vm.messages.count) { _, _ in
                            scrollToBottom(with: proxy)
                        }
                        .onChange(of: vm.currentResponse) { _, _ in
                            scrollToBottom(with: proxy)
                        }
                        .onChange(of: vm.currentThinking) { _, _ in
                            scrollToBottom(with: proxy)
                        }
                        .onChange(of: floatingComposerHeight) { _, _ in
                            scrollToBottom(with: proxy)
                        }
                        .onChange(of: vm.currentNode?.id) { _, _ in
                            scrollToBottom(with: proxy)
                        }
                    }
                    // 顶底双向消散遮罩：文字滚入 Header 或输入框时自然虚化
                    .mask(
                        VStack(spacing: 0) {
                            // 顶部消散（文字滚进 Header 区域时淡出）
                            LinearGradient(
                                colors: [.clear, .black],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: floatingHeaderHeight)
                            // 中间完全可见
                            Rectangle().fill(Color.black)
                            // 底部消散（文字滚向输入框时淡出）
                            LinearGradient(
                                colors: [.black, .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 80)
                        }
                    )

                    // Floating Header
                    ZStack(alignment: .top) {
                        HStack {
                            Text(vm.currentNode?.title ?? "Nous")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.leading, 76)
                        .padding(.trailing, 36)
                        .padding(.top, 22)

                        if voiceController.visibleSurface == .inWindow &&
                            VoiceCapsuleVisibilityPolicy.shouldShowCapsule(
                                isVoiceActive: voiceController.isActive,
                                status: voiceController.status,
                                hasPendingAction: voiceController.pendingAction != nil,
                                hasSummaryPreview: voiceController.summaryPreview != nil
                            ) {
                            VoiceCapsuleView(
                                status: voiceController.status,
                                subtitleText: voiceController.subtitleText,
                                audioLevel: voiceController.audioLevel,
                                hasPendingConfirmation: voiceController.pendingAction != nil,
                                summaryPreview: voiceController.summaryPreview,
                                onConfirm: voiceController.confirmPendingAction,
                                onCancel: voiceController.cancelPendingAction,
                                onDismissSummary: voiceController.dismissSummaryPreview
                            )
                            .padding(.top, 16)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .allowsHitTesting(voiceController.visibleSurface == .inWindow)
                        }
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: voiceController.isActive)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: voiceController.status.shouldDisplayPill)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: voiceController.pendingAction != nil)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: voiceController.summaryPreview)
                    .padding(.bottom, 36)
                    .background(
                        LinearGradient(
                            colors: [
                                AppColor.colaBeige,
                                AppColor.colaBeige.opacity(0.85),
                                AppColor.colaBeige.opacity(0.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .allowsHitTesting(false)
                    )
                    .allowsHitTesting(voiceController.pendingAction != nil || voiceController.summaryPreview != nil)
                    .readHeight { floatingHeaderHeight = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    // Floating Input
                    VStack(alignment: .leading, spacing: 10) {
                        if let clarificationCard = activeClarificationCard {
                            ClarificationCardView(card: clarificationCard) { option in
                                sendClarificationOption(option)
                            }
                        }

                        if !attachments.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(attachments) { attachment in
                                        AttachmentChip(attachment: attachment) {
                                            removeAttachment(attachment.id)
                                        }
                                    }
                                }
                            }
                        }

                        HStack(spacing: 12) {
                                Button(action: {
                                    if voiceController.isActive {
                                        onToggleVoiceMode()
                                    } else {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            isActionMenuExpanded.toggle()
                                        }
                                    }
                                }) {
                                    NativeGlassPanel(
                                        cornerRadius: 18,
                                        tintColor: voiceController.isActive
                                            ? NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.22)
                                            : AppColor.glassTint
                                    ) { EmptyView() }
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Image(systemName: voiceController.isActive ? "mic.fill" : (isActionMenuExpanded ? "xmark" : "plus"))
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundColor(voiceController.isActive ? AppColor.colaOrange : AppColor.secondaryText)
                                                .rotationEffect(.degrees(isActionMenuExpanded && !voiceController.isActive ? 90 : 0))
                                        )
                                        .overlay(
                                            Circle()
                                                .stroke(AppColor.panelStroke, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(voiceController.isActive ? "Stop Voice Mode" : "Actions")

                                ZStack(alignment: .leading) {
                                    RotatingComposerPromptLabel(
                                        inputText: vm.inputText,
                                        isFocused: isComposerFocused,
                                        horizontalPadding: 18
                                    )

                                    TextField("", text: $vm.inputText, axis: .vertical)
                                        .focused($isComposerFocused)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundColor(AppColor.colaDarkText)
                                        .lineLimit(1...6)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.leading, 18)
                                        .padding(.trailing, 18)
                                        .padding(.vertical, 10)
                                        .frame(minHeight: 36)
                                        .onSubmit(sendCurrentInput)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    NativeGlassPanel(
                                        cornerRadius: 18,
                                        tintColor: AppColor.glassTint
                                    ) { EmptyView() }
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(AppColor.panelStroke, lineWidth: 1)
                                )
                                .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)

                                if shouldSeparateComposerPrimaryAction {
                                    primaryActionButton(isSeparated: true)
                                        .transition(.scale(scale: 0.72, anchor: .leading).combined(with: .opacity))
                                }
                        }
                        .animation(
                            .timingCurve(0.68, -0.6, 0.32, 1.6, duration: 0.42),
                            value: shouldSeparateComposerPrimaryAction
                        )
                        .overlay(alignment: .bottomLeading) {
                            ActionMenuCapsule(
                                isExpanded: isActionMenuExpanded,
                                onFile: {
                                    isFileImporterPresented = true
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isActionMenuExpanded = false }
                                },
                                onPhoto: {
                                    isPhotosPickerPresented = true
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isActionMenuExpanded = false }
                                },
                                onVoice: {
                                    onToggleVoiceMode()
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isActionMenuExpanded = false }
                                },
                                canPickPhoto: canPickPhotoAttachment
                            )
                            .offset(y: -ActionMenuPopoutMetrics.sourceOffsetFromRowBottom)
                        }
                        .padding(.top, isActionMenuExpanded ? ActionMenuPopoutMetrics.reservedTopPadding : 0)
                        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isActionMenuExpanded)
                    }
                    .frame(maxWidth: composerMaxWidth)
                    .padding(.horizontal, 36)
                    .padding(.bottom, 16)
                    .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .onDrop(
                        of: AttachmentDropSupport.acceptedTypeIdentifiers,
                        isTargeted: $isImageDropTargeted,
                        perform: handleImageDrop
                    )
                    .overlay {
                        if isImageDropTargeted {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(AppColor.colaOrange.opacity(0.55), lineWidth: 1.5)
                        }
                    }
                    .readHeight { floatingComposerHeight = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.colaBeige)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .onChange(of: citationNodeIDs) { _, _ in
            isRelevantChatsExpanded = false
        }
        .overlay(alignment: .topLeading) {
            Button(action: {
                withAnimation(AppMotion.sidebarPanelSpring.animation) {
                    isSidebarVisible.toggle()
                }
            }) {
                ZStack {
                    NativeGlassPanel(cornerRadius: 16, tintColor: AppColor.glassTint) { EmptyView() }
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .stroke(AppColor.panelStroke, lineWidth: 1)
                        )
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppColor.secondaryText)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, isWelcomeState ? 24 : 16)
            .padding(.leading, 24)
        }
        .overlay(alignment: .topTrailing) {
            if !isWelcomeState {
                Button(action: {
                    withAnimation(AppMotion.markdownPanelSpring.animation) {
                        isScratchPadVisible.toggle()
                    }
                }) {
                    ZStack {
                        NativeGlassPanel(
                            cornerRadius: 16,
                            tintColor: isScratchPadVisible
                                ? NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.22)
                                : AppColor.glassTint
                        ) { EmptyView() }
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle()
                                .stroke(
                                    isScratchPadVisible ? AppColor.colaOrange.opacity(0.4) : AppColor.panelStroke,
                                    lineWidth: 1
                                )
                        )
                        Image(systemName: "note.text")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(isScratchPadVisible ? AppColor.colaOrange : AppColor.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
                .padding(.trailing, 24)
            }
        }
        .confirmationDialog("Add Attachment", isPresented: $isAttachmentMenuPresented, titleVisibility: .visible) {
            Button("File") {
                isFileImporterPresented = true
            }
            Button("Photo") {
                isPhotosPickerPresented = true
            }
            .disabled(!canPickPhotoAttachment)
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
        .photosPicker(
            isPresented: $isPhotosPickerPresented,
            selection: $selectedPhotoItems,
            maxSelectionCount: max(1, remainingImageAttachmentSlots),
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }

            Task {
                let loadedAttachments = await AttachmentExtractor.photoContexts(from: items)
                await MainActor.run {
                    appendAttachments(loadedAttachments)
                    selectedPhotoItems = []
                }
            }
        }
        .onChange(of: vm.currentNode?.id) { _, _ in
            attachments = []
            closeDownvotePopover()
        }
        .onChange(of: voiceAttachmentResetToken) { _, _ in
            attachments = []
        }
        .onChange(of: vm.inputText) { _, _ in
            if isActionMenuExpanded {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isActionMenuExpanded = false
                }
            }
        }
    }

    private func sendCurrentInput() {
        guard canSend else { return }
        let pendingAttachments = AttachmentLimitPolicy.limitingImageAttachments(attachments)
        attachments = []
        Task { await vm.send(attachments: pendingAttachments) }
    }

    private func handlePrimaryAction() {
        if vm.isGenerating {
            vm.stopGenerating()
            return
        }
        sendCurrentInput()
    }

    private func primaryActionButton(isSeparated: Bool) -> some View {
        Button(action: handlePrimaryAction) {
            Image(systemName: vm.isGenerating ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isSeparated ? .white : AppColor.secondaryText)
                .opacity(composerActionMotion.iconOpacity(isSeparated: isSeparated))
        }
        .buttonStyle(.plain)
        .frame(width: 36, height: 36)
        .background(
            primaryActionBackground(isSeparated: isSeparated)
        )
        .overlay(
            primaryActionStroke(isSeparated: isSeparated)
        )
        .shadow(
            color: AppColor.colaOrange.opacity(composerActionMotion.glowOpacity(
                isSeparated: isSeparated,
                canAct: canPrimaryAction
            )),
            radius: isSeparated ? 8 : 0,
            x: 0,
            y: isSeparated ? 2 : 0
        )
        .matchedGeometryEffect(id: "chatPrimaryAction", in: composerPrimaryActionNamespace)
        .disabled(!canPrimaryAction)
        .help(vm.isGenerating ? "Stop generating" : "Send")
    }

    private func primaryActionBackground(isSeparated: Bool) -> some View {
        Group {
            if isSeparated {
                ZStack {
                    Circle()
                        .fill(AppColor.colaOrange.opacity(composerActionMotion.fillOpacity(
                            isSeparated: isSeparated,
                            canAct: canPrimaryAction
                        )))

                    NativeGlassPanel(
                        cornerRadius: 18,
                        tintColor: primaryActionTint(isSeparated: isSeparated)
                    ) { EmptyView() }
                    .opacity(canPrimaryAction ? 0.52 : 0.9)
                }
            } else {
                Circle()
                    .fill(Color.clear)
            }
        }
    }

    private func primaryActionStroke(isSeparated: Bool) -> some View {
        Group {
            if isSeparated {
                Circle()
                    .stroke(canPrimaryAction ? Color.white.opacity(0.18) : AppColor.panelStroke, lineWidth: 1)
            } else {
                Circle()
                    .stroke(Color.clear, lineWidth: 1)
            }
        }
    }

    private func primaryActionTint(isSeparated: Bool) -> NSColor {
        let alpha = composerActionMotion.tintAlpha(
            isSeparated: isSeparated,
            canAct: canPrimaryAction
        )
        return NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: alpha)
    }

    private func sendClarificationOption(_ option: String) {
        vm.inputText = option
        sendCurrentInput()
    }

    private func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        appendAttachments(AttachmentExtractor.fileContexts(from: urls))
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canPickPhotoAttachment else { return false }
        Task {
            let droppedAttachments = await AttachmentExtractor.droppedImageContexts(from: providers)
            await MainActor.run {
                appendAttachments(droppedAttachments)
            }
        }
        return true
    }

    private func appendAttachments(_ newAttachments: [AttachedFileContext]) {
        var updatedAttachments = attachments
        for attachment in newAttachments {
            let alreadyExists = !AttachmentLimitPolicy.isImageAttachment(attachment) && updatedAttachments.contains {
                $0.name == attachment.name && $0.extractedText == attachment.extractedText
            }
            if !alreadyExists {
                updatedAttachments = AttachmentLimitPolicy.applyingImageLimit(
                    to: updatedAttachments,
                    appending: [attachment]
                )
            }
        }
        attachments = updatedAttachments
    }

    private func shouldShowRelevantChats(after message: Message) -> Bool {
        message.role == .assistant &&
        message.id == vm.messages.last(where: { $0.role == .assistant })?.id &&
        !vm.citations.isEmpty &&
        !vm.isGenerating
    }

    private func scrollToBottom(with proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(bottomScrollAnchor, anchor: .bottom)
        }
    }

    private func handleThumbsUpTap(for messageId: UUID) {
        closeDownvotePopover()
        if vm.feedback(forMessageId: messageId) == .up {
            vm.clearFeedback(forMessageId: messageId)
            return
        }
        vm.recordFeedback(forMessageId: messageId, feedback: .up)
    }

    private func handleThumbsDownTap(for messageId: UUID) {
        if vm.feedback(forMessageId: messageId) == .down {
            closeDownvotePopover()
            vm.clearFeedback(forMessageId: messageId)
            return
        }
        vm.recordFeedback(forMessageId: messageId, feedback: .down)
        prepareDownvotePopover(for: messageId)
    }

    private func prepareDownvotePopover(for messageId: UUID) {
        downvoteFeedbackReason = vm.feedbackReason(forMessageId: messageId)
        downvoteFeedbackNote = vm.feedbackNote(forMessageId: messageId)
        activeDownvotePopoverMessageId = messageId
    }

    private func saveDownvoteFeedback(for messageId: UUID) {
        vm.recordFeedbackDetail(
            forMessageId: messageId,
            feedback: .down,
            reason: downvoteFeedbackReason,
            note: downvoteFeedbackNote
        )
        closeDownvotePopover()
    }

    private func closeDownvotePopover() {
        activeDownvotePopoverMessageId = nil
        downvoteFeedbackReason = nil
        downvoteFeedbackNote = ""
    }

    private func isDownvotePopoverPresented(for messageId: UUID) -> Binding<Bool> {
        Binding(
            get: { activeDownvotePopoverMessageId == messageId },
            set: { isPresented in
                if !isPresented, activeDownvotePopoverMessageId == messageId {
                    closeDownvotePopover()
                }
            }
        )
    }
}

struct MessageBubble: View {
    let text: String
    let thinkingContent: String?
    let thinkingStartedAt: Date?
    let agentTraceRecords: [AgentTraceRecord]
    let isThinkingStreaming: Bool
    let isAgentTraceStreaming: Bool
    let isUser: Bool
    let source: MessageSource
    let timestamp: Date

    private let userBubbleMaxWidth: CGFloat = 520
    private let userParagraphSpacing: CGFloat = 10

    private var userParagraphTexts: [String] {
        Self.normalizedParagraphs(from: text)
    }

    private var assistantDisplayText: String {
        ClarificationCardParser.parse(text).displayText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isUser && !agentTraceRecords.isEmpty {
                AgentTraceAccordion(records: agentTraceRecords, isStreaming: isAgentTraceStreaming)
            }
            if let thinkingContent, !thinkingContent.isEmpty {
                ThinkingAccordion(
                    content: thinkingContent,
                    isStreaming: isThinkingStreaming,
                    startedAt: thinkingStartedAt
                )
            }
            let hasContent = isUser ? !userParagraphTexts.isEmpty : !assistantDisplayText.isEmpty
            if hasContent {
                if isUser {
                    HStack {
                        Spacer(minLength: 60)
                        VStack(alignment: .trailing, spacing: 2) {
                            VStack(alignment: .leading, spacing: userParagraphSpacing) {
                                ForEach(Array(userParagraphTexts.enumerated()), id: \.offset) { _, paragraph in
                                    Text(paragraph)
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundColor(AppColor.colaDarkText)
                                        .lineSpacing(6)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(AppColor.colaBubble)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            timestampRow
                                .padding(.trailing, 4)
                        }
                        .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            AssistantBubbleContent(displayText: assistantDisplayText)
                            Spacer(minLength: 0)
                        }
                        timestampRow
                    }
                }
            }
        }
    }

    private var timestampRow: some View {
        HStack(spacing: 4) {
            Text(timestamp, style: .time)
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(AppColor.secondaryText)
            if source == .voice {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.colaOrange.opacity(0.6))
                    .accessibilityLabel("Voice")
            }
        }
        .padding(.top, 2)
    }

    private static func normalizedParagraphs(from text: String) -> [String] {
        let paragraphBreakToken = "[[NOUS_PARAGRAPH_BREAK]]"
        let paragraphPreserved = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"\n\s*\n+"#, with: paragraphBreakToken, options: .regularExpression)
        let collapsedSoftBreaks = paragraphPreserved
            .replacingOccurrences(of: #"(?<=[。！？])\n"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=[.!?])\n"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")

        let rawParagraphs = collapsedSoftBreaks
            .components(separatedBy: paragraphBreakToken)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return mergeMechanicalSentenceParagraphs(in: rawParagraphs)
    }

    private static func mergeMechanicalSentenceParagraphs(in paragraphs: [String]) -> [String] {
        guard paragraphs.count >= 3 else { return paragraphs }

        var merged: [String] = []
        var buffer: [String] = []

        for paragraph in paragraphs {
            if shouldKeepStandaloneParagraph(paragraph) {
                flushBufferedParagraphs(&buffer, into: &merged)
                merged.append(paragraph)
                continue
            }

            if isMechanicalSentenceParagraph(paragraph) {
                buffer.append(paragraph)
                continue
            }

            flushBufferedParagraphs(&buffer, into: &merged)
            merged.append(paragraph)
        }

        flushBufferedParagraphs(&buffer, into: &merged)
        return merged
    }

    private static func flushBufferedParagraphs(_ buffer: inout [String], into merged: inout [String]) {
        guard !buffer.isEmpty else { return }

        if buffer.count >= 2 {
            merged.append(buffer.joined(separator: " "))
        } else {
            merged.append(contentsOf: buffer)
        }

        buffer.removeAll(keepingCapacity: true)
    }

    private static func shouldKeepStandaloneParagraph(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let patterns = [
            #"^[-*•]\s+"#,
            #"^\d+\.\s+"#,
            #"^>\s+"#,
            #"^#{1,6}\s+"#,
            #"^[A-Z][^:]{0,24}:\s*$"#
        ]

        return patterns.contains {
            trimmed.range(of: $0, options: .regularExpression) != nil
        }
    }

    private static func isMechanicalSentenceParagraph(_ paragraph: String) -> Bool {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count <= 110 else { return false }

        let sentenceEndCount = trimmed
            .filter { ".!?。！？".contains($0) }
            .count

        return sentenceEndCount <= 2
    }
}

struct StreamingAssistantPresentation {
    let isGenerating: Bool
    let currentThinking: String
    let currentThinkingStartedAt: Date?
    let currentResponse: String
    let currentAgentTraceIsEmpty: Bool

    private static let placeholderThinkingContent = "Preparing context and shaping the reply."

    private var displayThinkingContent: String {
        let trimmedThinking = currentThinking.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedThinking.isEmpty ? Self.placeholderThinkingContent : currentThinking
    }

    var showsPendingThinking: Bool {
        isGenerating && currentResponse.isEmpty
    }

    var pendingThinkingContent: String {
        displayThinkingContent
    }

    var pendingThinkingStartedAt: Date? {
        currentThinkingStartedAt
    }

    var showsPendingAgentTrace: Bool {
        isGenerating && !currentAgentTraceIsEmpty && currentResponse.isEmpty
    }

    var showsAssistantDraft: Bool {
        isGenerating && !currentResponse.isEmpty
    }

    var draftThinkingContent: String? {
        guard showsAssistantDraft else { return nil }
        return displayThinkingContent
    }

    var draftThinkingStartedAt: Date? {
        guard draftThinkingContent != nil else { return nil }
        return currentThinkingStartedAt
    }

    var isDraftThinkingStreaming: Bool {
        showsAssistantDraft
    }

    var isDraftAgentTraceStreaming: Bool {
        false
    }
}

private struct AssistantBubbleContent: View {
    let displayText: String

    private let assistantTextMaxWidth: CGFloat = 520

    var body: some View {
        // Single parse per body recompute via Swift `let` binding.
        // Computed properties are NOT memoized by SwiftUI — `let` here ensures
        // the renderer and animation modifier reference the same parse output.
        let segments = ChatMarkdownRenderer.parse(displayText)
        return ChatMarkdownView(segments: segments)
            .frame(maxWidth: assistantTextMaxWidth, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .animation(.easeOut(duration: 0.15), value: segments.count)
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? AppColor.colaOrange : AppColor.colaDarkText.opacity(0.5))
        .animation(.easeInOut(duration: 0.15), value: copied)
        .help("Copy response")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}

struct AssistantFeedbackButton: View {
    let symbolName: String
    let isSelected: Bool
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AppColor.colaOrange : AppColor.colaDarkText.opacity(0.5))
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .help(helpText)
    }
}

enum ActionMenuPopoutMetrics {
    static let reservedTopPadding: CGFloat = 68
    static let sourceOffsetFromRowBottom: CGFloat = 44
    static let itemHeight: CGFloat = 52
    static let itemWidth: CGFloat = 52
    static let capsuleCornerRadius: CGFloat = 18
}

struct ActionMenuCapsule: View {
    let isExpanded: Bool
    let onFile: () -> Void
    let onPhoto: () -> Void
    let onVoice: () -> Void
    let canPickPhoto: Bool

    private let motion = ActionMenuSeparationMotion()

    private var capsuleScale: CGSize {
        motion.capsuleScale(isExpanded: isExpanded)
    }

    var body: some View {
        HStack(spacing: 0) {
            ActionMenuButton(
                icon: "doc",
                title: "File",
                isExpanded: isExpanded,
                separationIndex: 0,
                action: onFile
            )

            ActionMenuDivider(isExpanded: isExpanded)

            ActionMenuButton(
                icon: "photo",
                title: "Photo",
                isExpanded: isExpanded,
                separationIndex: 1,
                isEnabled: canPickPhoto,
                action: onPhoto
            )

            ActionMenuDivider(isExpanded: isExpanded)

            ActionMenuButton(
                icon: "mic",
                title: "Voice",
                isExpanded: isExpanded,
                separationIndex: 2,
                action: onVoice
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            NativeGlassPanel(
                cornerRadius: ActionMenuPopoutMetrics.capsuleCornerRadius,
                tintColor: AppColor.glassTint
            ) { EmptyView() }
        )
        .overlay(
            RoundedRectangle(cornerRadius: ActionMenuPopoutMetrics.capsuleCornerRadius, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
        .scaleEffect(x: capsuleScale.width, y: capsuleScale.height, anchor: .bottomLeading)
        .offset(
            x: motion.capsuleOffset(isExpanded: isExpanded).width,
            y: motion.capsuleOffset(isExpanded: isExpanded).height
        )
        .opacity(motion.capsuleOpacity(isExpanded: isExpanded))
        .blur(radius: motion.capsuleBlur(isExpanded: isExpanded))
        .shadow(color: .black.opacity(isExpanded ? 0.12 : 0), radius: 12, x: 0, y: 6)
        .frame(height: ActionMenuPopoutMetrics.reservedTopPadding, alignment: .bottomLeading)
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isExpanded)
    }
}

struct ActionMenuDivider: View {
    let isExpanded: Bool

    var body: some View {
        Rectangle()
            .fill(AppColor.panelStroke.opacity(isExpanded ? 0.62 : 0))
            .frame(width: 1, height: 30)
            .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }
}

struct ActionMenuButton: View {
    let icon: String
    let title: String
    let isExpanded: Bool
    let separationIndex: Int
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovered = false
    private let motion = ActionMenuSeparationMotion()

    private var emergenceAnimation: Animation {
        .easeOut(duration: 0.2)
            .delay(motion.delay(for: separationIndex, isExpanded: isExpanded))
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                Text(title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundColor(isEnabled ? AppColor.colaDarkText : AppColor.secondaryText.opacity(0.72))
            .frame(width: ActionMenuPopoutMetrics.itemWidth, height: ActionMenuPopoutMetrics.itemHeight)
            .overlay(
                ZStack {
                    if isHovered && isEnabled {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(AppColor.colaDarkText.opacity(0.04))
                            .padding(2)
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isExpanded || !isEnabled)
        .opacity(motion.itemOpacity(isExpanded: isExpanded, isEnabled: isEnabled))
        .scaleEffect(isExpanded ? (isHovered && isEnabled ? 1.035 : 1.0) : 0.96)
        .offset(
            x: motion.itemOffset(for: separationIndex, isExpanded: isExpanded).width,
            y: motion.itemOffset(for: separationIndex, isExpanded: isExpanded).height
        )
        .blur(radius: isExpanded ? 0 : 3)
        .animation(emergenceAnimation, value: isExpanded)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityHidden(!isExpanded)
    }
}

struct DownvoteFeedbackPopover: View {
    @Binding var selectedReason: JudgeFeedbackReason?
    @Binding var note: String
    let onSave: () -> Void
    let onSkip: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8, alignment: .leading),
        GridItem(.flexible(), spacing: 8, alignment: .leading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What felt off?")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)

                Text("This helps Nous stop repeating the same kind of interjection.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(JudgeFeedbackReason.allCases) { reason in
                    FeedbackReasonChip(
                        title: reason.title,
                        isSelected: selectedReason == reason
                    ) {
                        selectedReason = selectedReason == reason ? nil : reason
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Optional note")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)

                TextField("What felt off?", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                    .lineLimit(2...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        NativeGlassPanel(cornerRadius: 16, tintColor: AppColor.glassTint) { EmptyView() }
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(AppColor.panelStroke, lineWidth: 1)
                    )
            }

            HStack(spacing: 10) {
                Button("Skip", action: onSkip)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)

                Spacer()

                Button(action: onSave) {
                    Text("Save")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(AppColor.colaOrange)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(
            NativeGlassPanel(cornerRadius: 24, tintColor: AppColor.glassTint) { EmptyView() }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
    }
}

struct FeedbackReasonChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(isSelected ? AppColor.colaOrange : AppColor.colaDarkText.opacity(0.74))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isSelected ? AppColor.colaOrange.opacity(0.14) : AppColor.surfaceSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isSelected ? AppColor.colaOrange.opacity(0.35) : AppColor.panelStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: HeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(HeightPreferenceKey.self, perform: onChange)
    }
}
