import PhotosUI
import SwiftUI

struct ChatArea: View {
    @Bindable var vm: ChatViewModel
    @Binding var isSidebarVisible: Bool
    @Binding var isScratchPadVisible: Bool
    var onNavigateToNode: (NousNode) -> Void = { _ in }

    @State private var attachments: [AttachedFileContext] = []
    @State private var isRelevantChatsExpanded = false
    @State private var isAttachmentMenuPresented = false
    @State private var isFileImporterPresented = false
    @State private var isPhotosPickerPresented = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var floatingHeaderHeight: CGFloat = 76
    @State private var floatingComposerHeight: CGFloat = 124
    @State private var activeDownvotePopoverMessageId: UUID?
    @State private var downvoteFeedbackReason: JudgeFeedbackReason?
    @State private var downvoteFeedbackNote: String = ""

    private let bottomScrollAnchor = "chat-bottom-anchor"
    private let bottomVisibleSpacing: CGFloat = 53
    
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

    var body: some View {
        VStack(spacing: 0) {
            if isWelcomeState {
                WelcomeView(
                    inputText: $vm.inputText,
                    attachments: attachments,
                    onPickAttachment: { isAttachmentMenuPresented = true },
                    onRemoveAttachment: removeAttachment,
                    onSend: sendCurrentInput,
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
                            VStack(spacing: 24) {
                                ForEach(vm.messages) { msg in
                                    VStack(alignment: .leading, spacing: 4) {
                                        MessageBubble(
                                            text: msg.content,
                                            thinkingContent: msg.thinkingContent,
                                            isThinkingStreaming: false,
                                            isUser: msg.role == .user
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
                                                            : "Mark this interjection as useful (event \(eventId.uuidString.prefix(8)))"
                                                    ) {
                                                        handleThumbsUpTap(for: msg.id)
                                                    }

                                                    AssistantFeedbackButton(
                                                        symbolName: feedback == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                                                        isSelected: feedback == .down,
                                                        helpText: feedback == .down
                                                            ? "Clear not useful feedback (event \(eventId.uuidString.prefix(8)))"
                                                            : "Mark this interjection as not useful (event \(eventId.uuidString.prefix(8)))"
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

                                                CopyButton(text: msg.content)
                                            }
                                            .font(.footnote)
                                            .foregroundStyle(AppColor.colaDarkText.opacity(0.5))
                                        }
                                    }
                                }
                                if vm.isGenerating && (!vm.currentThinking.isEmpty || !vm.currentResponse.isEmpty) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        MessageBubble(
                                            text: vm.currentResponse,
                                            thinkingContent: vm.currentThinking.isEmpty ? nil : vm.currentThinking,
                                            isThinkingStreaming: vm.currentResponse.isEmpty, // 只要 currentResponse 还是空，就代表还在思考阶段
                                            isUser: false
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
                            .padding(.top, floatingHeaderHeight + 24)
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

                    // Floating Header
                    VStack {
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
                    }
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
                    .allowsHitTesting(false)
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
                            Button(action: { isAttachmentMenuPresented = true }) {
                                NativeGlassPanel(cornerRadius: 18, tintColor: AppColor.glassTint) { EmptyView() }
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Image(systemName: "plus")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(AppColor.secondaryText)
                                    )
                                    .overlay(
                                        Circle()
                                            .stroke(AppColor.panelStroke, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)

                            TextField("", text: $vm.inputText, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText)
                                .lineLimit(1...4)
                                .padding(.horizontal, 18)
                                .frame(height: 36)
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
                                .onSubmit(sendCurrentInput)

                            Button(action: handlePrimaryAction) {
                                Image(systemName: vm.isGenerating ? "stop.fill" : "arrow.up")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 36, height: 36)
                            .background(
                                NativeGlassPanel(
                                    cornerRadius: 18,
                                    tintColor: canPrimaryAction
                                        ? NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.88)
                                        : NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.18)
                                ) { EmptyView() }
                            )
                            .overlay(
                                Circle()
                                    .stroke(canPrimaryAction ? Color.white.opacity(0.18) : AppColor.panelStroke, lineWidth: 1)
                            )
                            .disabled(!canPrimaryAction)
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.bottom, 16)
                    .padding(.top, 40)
                    .background(
                        LinearGradient(
                            colors: [
                                AppColor.colaBeige.opacity(0.0),
                                AppColor.colaBeige.opacity(0.85),
                                AppColor.colaBeige,
                                AppColor.colaBeige
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .allowsHitTesting(false)
                    )
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
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
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
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
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
            maxSelectionCount: 6,
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
    }

    private func sendCurrentInput() {
        guard canSend else { return }
        let pendingAttachments = attachments
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

    private func appendAttachments(_ newAttachments: [AttachedFileContext]) {
        for attachment in newAttachments {
            let alreadyExists = attachments.contains {
                $0.name == attachment.name && $0.extractedText == attachment.extractedText
            }
            if !alreadyExists {
                attachments.append(attachment)
            }
        }
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
    let isThinkingStreaming: Bool
    let isUser: Bool

    var body: some View {
        let parsed = isUser
            ? ClarificationContent(displayText: text, card: nil, keepsQuickActionMode: false)
            : ClarificationCardParser.parse(text)

        VStack(alignment: .leading, spacing: 6) {
            if let thinkingContent, !thinkingContent.isEmpty {
                ThinkingAccordion(content: thinkingContent, isStreaming: isThinkingStreaming)
            }
            if !parsed.displayText.isEmpty {
                if isUser {
                    HStack {
                        Spacer(minLength: 0)
                        Text(parsed.displayText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(AppColor.colaDarkText)
                            .lineSpacing(4)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(AppColor.colaBubble)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .textSelection(.enabled)
                    }
                } else {
                    HStack {
                        Text(parsed.displayText)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(AppColor.colaDarkText)
                            .lineSpacing(6)
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
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
