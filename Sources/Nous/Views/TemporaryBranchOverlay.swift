import AppKit
import SwiftUI

enum TemporaryBranchFocusStyle {
    static let backgroundBlurRadius: CGFloat = 22
    static let backgroundDimOpacity = 0.58
    static let drawsSourceMessageOutline = false
}

enum TemporaryBranchMembraneStyle {
    static let drawsFramedPanel = false
    static let inlineComposerMaxWidth: CGFloat = ComposerTextInputMetrics.chatComposerMaxWidth
    static let primaryComposerMinHeight: CGFloat = ComposerTextInputMetrics.minimumControlHeight
    static let primaryComposerCornerRadius: CGFloat = ComposerTextInputMetrics.leadingActionCornerRadius
    static let sourceAnchorOpacity = 0.52
    static let dimmedContentOpacity = 0.34
    static let focusedContentOpacity = 1.0
    static let inlineBlurRadius: CGFloat = 9
    static let sourceQuoteMarkerHeight: CGFloat = 32
    static let recordMarkerHeight: CGFloat = 64
    static let focusedSourceTopPadding: CGFloat = 118
    static let focusedSourceBottomClearance: CGFloat = 44
    static let focusedSourceCollapsedMaxHeight: CGFloat = 280
    static let focusedSourceExpandedMaxHeight: CGFloat = 460
    static let focusedSourceToggleThresholdChars: Int = 320
}

enum TemporaryBranchTriggerHitTarget {
    static let buttonDiameter: CGFloat = 28
    static let buttonEdgeGap: CGFloat = 14
    static let userButtonOutsideOffset: CGFloat = buttonDiameter + buttonEdgeGap
    static let assistantButtonOutsideOffset: CGFloat = buttonDiameter + buttonEdgeGap
    static let buttonVerticalOffset: CGFloat = 2
    static let hoverExitGraceDuration: TimeInterval = 0.22
}

struct TemporaryBranchOverlay: View {
    @Bindable var branch: TemporaryBranchViewModel
    let onSend: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .opacity(TemporaryBranchFocusStyle.backgroundDimOpacity)
                .ignoresSafeArea()

            TemporaryBranchInlineComposer(
                branch: branch,
                onSend: onSend,
                onPickAttachment: {},
                onPickPhoto: {},
                onYouTube: {},
                onVoice: {},
                canPickPhoto: false,
                onRemoveAttachment: { _ in },
                onImageDrop: { _ in false }
            )
            .padding(.horizontal, 48)
        }
        .overlay(alignment: .topLeading) {
            TemporaryBranchCloseButton(action: onClose)
                .padding(.top, 24)
                .padding(.leading, 24)
        }
    }
}

struct TemporaryBranchInlineComposer: View {
    @Bindable var branch: TemporaryBranchViewModel
    let onSend: () -> Void
    let onPickAttachment: () -> Void
    let onPickPhoto: () -> Void
    let onYouTube: () -> Void
    let onVoice: () -> Void
    let canPickPhoto: Bool
    let onRemoveAttachment: (UUID) -> Void
    let onImageDrop: ([NSItemProvider]) -> Bool

    @State private var isActionMenuExpanded = false
    @FocusState private var isComposerFocused: Bool

    private var canSend: Bool {
        (
            !branch.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !branch.attachments.isEmpty
        ) &&
        !branch.isGenerating
    }

    private var shouldShowPrimaryAction: Bool {
        branch.isGenerating ||
        !branch.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !branch.attachments.isEmpty
    }

    var body: some View {
        focusMembrane
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    isComposerFocused = true
                }
            }
            .onChange(of: branch.inputText) { _, _ in
                if isActionMenuExpanded {
                    withAnimation(ActionMenuSoftStaggerAnimation.close) {
                        isActionMenuExpanded = false
                    }
                }
            }
    }

    private var focusMembrane: some View {
        composerStack
            .frame(maxWidth: TemporaryBranchMembraneStyle.inlineComposerMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composerStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            TemporaryBranchSourceQuote(branch: branch)
            branchAttachmentChips
            primaryBranchComposer
        }
    }

    private var primaryBranchComposer: some View {
        HStack(spacing: ComposerTextInputMetrics.controlSpacing) {
            branchLeadingActionButton
            branchTextField

            if shouldShowPrimaryAction {
                branchPrimaryActionButton
                    .transition(.scale(scale: 0.72, anchor: .leading).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomLeading) {
            ActionMenuCapsule(
                isExpanded: isActionMenuExpanded,
                onFile: {
                    onPickAttachment()
                    closeActionMenu()
                },
                onPhoto: {
                    onPickPhoto()
                    closeActionMenu()
                },
                onYouTube: {
                    onYouTube()
                    closeActionMenu()
                },
                onVoice: {
                    onVoice()
                    closeActionMenu()
                },
                canPickPhoto: canPickPhoto
            )
            .offset(y: -ActionMenuPopoutMetrics.sourceOffsetFromRowBottom)
        }
        .padding(.top, isActionMenuExpanded ? ActionMenuPopoutMetrics.reservedTopPadding : 0)
        .animation(
            .timingCurve(0.68, -0.6, 0.32, 1.6, duration: 0.42),
            value: shouldShowPrimaryAction
        )
        .animation(ActionMenuSoftStaggerAnimation.stateChange(isExpanded: isActionMenuExpanded), value: isActionMenuExpanded)
        .onDrop(
            of: AttachmentDropSupport.allFileTypeIdentifiers,
            isTargeted: nil,
            perform: onImageDrop
        )
    }

    @ViewBuilder
    private var branchAttachmentChips: some View {
        if !branch.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(branch.attachments) { attachment in
                        AttachmentChip(attachment: attachment) {
                            onRemoveAttachment(attachment.id)
                        }
                    }
                }
            }
        }
    }

    private var branchLeadingActionButton: some View {
        ComposerLeadingActionButton(
            systemImage: isActionMenuExpanded ? "xmark" : "plus",
            isMenuExpanded: isActionMenuExpanded,
            isVoiceActive: false,
            size: ComposerTextInputMetrics.leadingActionSize,
            cornerRadius: ComposerTextInputMetrics.leadingActionCornerRadius,
            action: {
                isComposerFocused = true
                withAnimation(ActionMenuSoftStaggerAnimation.stateChange(isExpanded: !isActionMenuExpanded)) {
                    isActionMenuExpanded.toggle()
                }
            }
        )
        .help("Actions")
    }

    private var branchTextField: some View {
        ZStack(alignment: .topLeading) {
            TextField("", text: $branch.inputText, axis: .vertical)
                .focused($isComposerFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(AppColor.colaDarkText)
                .lineLimit(1...ComposerTextInputMetrics.maxVisibleLines)
                .frame(maxWidth: .infinity, minHeight: ComposerTextInputMetrics.minimumTextHeight, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 18)
                .padding(.trailing, 18)
                .padding(.vertical, ComposerTextInputMetrics.verticalPadding)
                .onSubmit {
                    if canSend {
                        onSend()
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: TemporaryBranchMembraneStyle.primaryComposerMinHeight, alignment: .leading)
        .background(
            ComposerTextInputGlassBackground(cornerRadius: TemporaryBranchMembraneStyle.primaryComposerCornerRadius)
        )
        .onDrop(
            of: AttachmentDropSupport.allFileTypeIdentifiers,
            isTargeted: nil,
            perform: onImageDrop
        )
    }

    private var branchPrimaryActionButton: some View {
        Button(action: onSend) {
            Image(systemName: branch.isGenerating ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: ComposerTextInputMetrics.leadingActionSize, height: ComposerTextInputMetrics.leadingActionSize)
                .background(
                    ZStack {
                        Circle()
                            .fill(AppColor.colaOrange.opacity(canSend ? 0.92 : 0.28))

                        NativeGlassPanel(
                            cornerRadius: ComposerTextInputMetrics.leadingActionCornerRadius,
                            tintColor: NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: canSend ? 0.30 : 0.12)
                        ) { EmptyView() }
                        .opacity(canSend ? 0.52 : 0.9)
                    }
                )
                .overlay(
                    Circle()
                        .stroke(canSend ? Color.white.opacity(0.18) : AppColor.panelStroke, lineWidth: 1)
                )
                .shadow(
                    color: AppColor.colaOrange.opacity(canSend ? 0.28 : 0),
                    radius: canSend ? 8 : 0,
                    x: 0,
                    y: canSend ? 2 : 0
                )
                .opacity(canSend ? 1 : 0.72)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .help(branch.isGenerating ? "Branch is responding" : "Send branch message")
    }

    private func closeActionMenu() {
        withAnimation(ActionMenuSoftStaggerAnimation.close) {
            isActionMenuExpanded = false
        }
    }
}

struct TemporaryBranchSourceQuote: View {
    @Bindable var branch: TemporaryBranchViewModel

    var body: some View {
        if !branch.sourceExcerpt.isEmpty {
            branchQuote(text: branch.sourceExcerpt)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func branchQuote(text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule(style: .continuous)
                .fill(AppColor.colaOrange.opacity(0.42))
                .frame(width: 3, height: TemporaryBranchMembraneStyle.sourceQuoteMarkerHeight)

            Text("“\(text)”")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .italic()
                .foregroundStyle(AppColor.colaDarkText.opacity(0.56))
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct TemporaryBranchTranscript: View {
    @Bindable var branch: TemporaryBranchViewModel
    let onRegenerate: () -> Void

    var body: some View {
        if !branch.messages.isEmpty || !branch.currentResponse.isEmpty || branch.isGenerating {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(branch.messages) { message in
                    TemporaryBranchBubble(
                        text: message.content,
                        attachments: message.attachments,
                        isUser: message.role == .user,
                        feedback: branch.feedback(forMessageId: message.id),
                        canRegenerate: branch.canRegenerateAssistantMessage(message.id),
                        onFeedback: { feedback in
                            branch.recordFeedback(forMessageId: message.id, feedback: feedback)
                        },
                        onRegenerate: onRegenerate
                    )
                }

                if branch.isGenerating {
                    TemporaryBranchPendingThinking(branch: branch)
                }

                if !branch.currentResponse.isEmpty {
                    TemporaryBranchBubble(
                        text: branch.currentResponse,
                        attachments: [],
                        isUser: false,
                        feedback: nil,
                        canRegenerate: false,
                        onFeedback: { _ in },
                        onRegenerate: {}
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TemporaryBranchPendingThinking: View {
    @Bindable var branch: TemporaryBranchViewModel

    var body: some View {
        HStack {
            ThinkingAccordion(
                content: "Preparing context and shaping the branch reply.",
                isStreaming: true,
                startedAt: branch.currentThinkingStartedAt
            )
            Spacer(minLength: 0)
        }
    }
}

struct TemporaryBranchRecordMarker: View {
    let record: TemporaryBranchRecord
    let action: () -> Void
    let onMemoryCandidateAction: (UUID, TemporaryBranchMemoryCandidateAction) -> Void

    private var visibleMemoryCandidates: [TemporaryBranchMemoryCandidate] {
        record.memoryCandidates.filter { candidate in
            candidate.scope != .ignore &&
            (candidate.scope != .project || RetiredFeaturePolicy.projectSurfacesEnabled)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            markerSummary
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .help("Open side thought")

            if !visibleMemoryCandidates.isEmpty {
                memoryCandidateList
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var markerSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule(style: .continuous)
                .fill(AppColor.colaOrange.opacity(0.34))
                .frame(width: 3, height: TemporaryBranchMembraneStyle.recordMarkerHeight)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppColor.colaOrange.opacity(0.78))

                    Text("Side thought")
                        .font(.system(size: 11, weight: .bold, design: .rounded))

                    Text(record.messageCountLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(AppColor.secondaryText.opacity(0.8))
                }

                Text("“\(record.sourceExcerpt)”")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .italic()
                    .foregroundStyle(AppColor.colaDarkText.opacity(0.58))
                    .lineLimit(2)

                if !record.previewText.isEmpty {
                    Text(record.previewText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(AppColor.secondaryText.opacity(0.72))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var memoryCandidateList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Worth remembering")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(AppColor.secondaryText.opacity(0.82))

            ForEach(visibleMemoryCandidates) { candidate in
                HStack(alignment: .top, spacing: 8) {
                    Text(candidate.content)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppColor.colaDarkText.opacity(0.72))
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    memoryCandidateActions(candidate)
                }
            }
        }
        .padding(.leading, 23)
        .frame(maxWidth: 520, alignment: .leading)
    }

    @ViewBuilder
    private func memoryCandidateActions(_ candidate: TemporaryBranchMemoryCandidate) -> some View {
        switch candidate.status {
        case .pending, .accepted:
            HStack(spacing: 8) {
                Button(saveLabel(for: candidate)) {
                    onMemoryCandidateAction(candidate.id, .save)
                }
                .buttonStyle(.plain)

                Button("Ignore") {
                    onMemoryCandidateAction(candidate.id, .ignore)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColor.secondaryText.opacity(0.74))
            }
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(AppColor.colaOrange.opacity(0.82))
        case .applied:
            Text(savedLabel(for: candidate))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(AppColor.secondaryText.opacity(0.78))
        case .rejected:
            Text("Ignored")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(AppColor.secondaryText.opacity(0.68))
        }
    }

    private func saveLabel(for candidate: TemporaryBranchMemoryCandidate) -> String {
        switch candidate.scope {
        case .project:
            return "Unavailable"
        case .global:
            return "Save to Memory"
        case .conversation:
            return "Save to Thread"
        case .ignore:
            return "Ignore"
        }
    }

    private func savedLabel(for candidate: TemporaryBranchMemoryCandidate) -> String {
        switch candidate.scope {
        case .project:
            return "Unavailable"
        case .global:
            return "Saved to Long-term Memory"
        case .conversation:
            return "Saved to Thread Memory"
        case .ignore:
            return "Ignored"
        }
    }
}

private struct TemporaryBranchBubble: View {
    let text: String
    let attachments: [AttachedFileContext]
    let isUser: Bool
    let feedback: JudgeFeedback?
    let canRegenerate: Bool
    let onFeedback: (JudgeFeedback) -> Void
    let onRegenerate: () -> Void

    private let bubbleMaxWidth: CGFloat = 520

    var body: some View {
        if isUser {
            userBubble
        } else {
            assistantReply
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)

            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.system(size: 14, weight: .regular))
                    .lineSpacing(6)
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !attachments.isEmpty {
                    MessageAttachmentRow(attachments: attachments, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AppColor.colaOrange.opacity(0.86))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
        }
    }

    private var assistantReply: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                AssistantBubbleContent(displayText: text)
                Spacer(minLength: 0)
            }

            TemporaryBranchAssistantActions(
                text: text,
                feedback: feedback,
                canRegenerate: canRegenerate,
                onFeedback: onFeedback,
                onRegenerate: onRegenerate
            )
        }
    }
}

private struct TemporaryBranchAssistantActions: View {
    let text: String
    let feedback: JudgeFeedback?
    let canRegenerate: Bool
    let onFeedback: (JudgeFeedback) -> Void
    let onRegenerate: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            AssistantFeedbackButton(
                symbolName: feedback == .up ? "hand.thumbsup.fill" : "hand.thumbsup",
                isSelected: feedback == .up,
                helpText: feedback == .up ? "Clear useful feedback" : "Mark this branch reply as useful"
            ) {
                onFeedback(.up)
            }

            AssistantFeedbackButton(
                symbolName: feedback == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                isSelected: feedback == .down,
                helpText: feedback == .down ? "Clear not useful feedback" : "Mark this branch reply as not useful"
            ) {
                onFeedback(.down)
            }

            if canRegenerate {
                AssistantFeedbackButton(
                    symbolName: "arrow.clockwise",
                    isSelected: false,
                    helpText: "Regenerate branch reply",
                    action: onRegenerate
                )
            }

            CopyButton(text: text)
        }
        .font(.footnote)
        .foregroundStyle(AppColor.colaDarkText.opacity(0.5))
    }
}

struct TemporaryBranchCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppColor.colaDarkText.opacity(0.66))
                .frame(width: 32, height: 32)
                .background(AppColor.subtleFill)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close branch")
    }
}

struct TemporaryBranchTriggerButton: View {
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppColor.colaOrange.opacity(0.92))
                .frame(
                    width: TemporaryBranchTriggerHitTarget.buttonDiameter,
                    height: TemporaryBranchTriggerHitTarget.buttonDiameter
                )
                .background(
                    Circle()
                        .fill(AppColor.colaDarkText.opacity(0.26))
                )
                .overlay(
                    Circle()
                        .stroke(AppColor.colaOrange.opacity(0.22), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.92)
        .animation(.easeOut(duration: 0.14), value: isVisible)
        .help("Open temporary side thought")
    }
}
