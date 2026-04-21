import PhotosUI
import SwiftUI

struct ChatArea: View {
    @Bindable var vm: ChatViewModel
    @Binding var isSidebarVisible: Bool
    var onNavigateToNode: (NousNode) -> Void = { _ in }

    @State private var attachments: [AttachedFileContext] = []
    @State private var isRelevantChatsExpanded = false
    @State private var isAttachmentMenuPresented = false
    @State private var isFileImporterPresented = false
    @State private var isPhotosPickerPresented = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    
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
                                    if msg.role == .assistant,
                                       let eventId = vm.judgeEventId(forMessageId: msg.id) {
                                        HStack(spacing: 4) {
                                            Button(action: { vm.recordFeedback(forMessageId: msg.id, feedback: .up) }) {
                                                Image(systemName: "hand.thumbsup")
                                                    .frame(width: 24, height: 24)
                                                    .contentShape(Rectangle())
                                            }.buttonStyle(.plain)
                                            Button(action: { vm.recordFeedback(forMessageId: msg.id, feedback: .down) }) {
                                                Image(systemName: "hand.thumbsdown")
                                                    .frame(width: 24, height: 24)
                                                    .contentShape(Rectangle())
                                            }.buttonStyle(.plain)
                                        }
                                        .font(.footnote)
                                        .foregroundStyle(AppColor.colaDarkText.opacity(0.5))
                                        .help("Was this interjection useful? (event \(eventId.uuidString.prefix(8)))")
                                    }
                                }
                            }
                            if vm.isGenerating && !vm.currentThinking.isEmpty && vm.currentResponse.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        ThinkingAccordion(
                                            content: vm.currentThinking,
                                            isStreaming: true
                                        )
                                        Spacer()
                                    }
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
                            if !vm.currentResponse.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    MessageBubble(
                                        text: vm.currentResponse,
                                        thinkingContent: vm.currentThinking.isEmpty ? nil : vm.currentThinking,
                                        isThinkingStreaming: vm.isGenerating && !vm.currentThinking.isEmpty,
                                        isUser: false
                                    )
                                    if !vm.citations.isEmpty && vm.isGenerating {
                                        RAGCitationView(
                                            citations: vm.citations,
                                            isExpanded: $isRelevantChatsExpanded,
                                            onOpenSource: onNavigateToNode
                                        )
                                        .padding(.top, 4)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 36)
                        .padding(.top, 76) // Space to scroll past floating header
                        .padding(.bottom, 124) // Space to scroll past floating input
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
                        .padding(.top, 20)
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
                                Circle()
                                    .fill(AppColor.surfaceSecondary)
                                    .frame(width: 34, height: 34)
                                    .overlay(
                                        Image(systemName: "plus")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(AppColor.secondaryText)
                                    )
                                    .overlay(
                                        Circle()
                                            .stroke(AppColor.panelStroke, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)

                            TextField("...", text: $vm.inputText, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText)
                                .lineLimit(1...4)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
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
                            .frame(width: 34, height: 34)
                            .background(
                                NativeGlassPanel(
                                    cornerRadius: 17,
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
                    Circle()
                        .fill(AppColor.subtleFill)
                        .overlay(
                            Circle()
                                .stroke(AppColor.panelStroke, lineWidth: 1)
                        )
                        .frame(width: isWelcomeState ? 32 : 28, height: isWelcomeState ? 32 : 28)
                    Image(systemName: "sidebar.left")
                        .font(.system(size: isWelcomeState ? 12 : 11, weight: .medium))
                        .foregroundColor(AppColor.secondaryText)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, isWelcomeState ? 24 : 16)
            .padding(.leading, 24)
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
