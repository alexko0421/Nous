import AppKit
import SwiftUI

enum TemporaryBranchFocusStyle {
    static let backgroundBlurRadius: CGFloat = 22
    static let backgroundDimOpacity = 0.58
    static let drawsSourceMessageOutline = false
}

enum TemporaryBranchMembraneStyle {
    static let drawsFramedPanel = false
    static let inlineComposerMaxWidth: CGFloat = 520
    static let primaryComposerMinHeight: CGFloat = ComposerTextInputMetrics.minimumControlHeight
    static let primaryComposerCornerRadius: CGFloat = 18
    static let sourceAnchorOpacity = 0.52
    static let dimmedContentOpacity = 0.34
    static let focusedContentOpacity = 1.0
    static let inlineBlurRadius: CGFloat = 9
    static let sourceQuoteMarkerHeight: CGFloat = 32
    static let recordMarkerHeight: CGFloat = 64
    static let focusedSourceTopPadding: CGFloat = 118
    static let focusedSourceBottomClearance: CGFloat = 44
}

enum TemporaryBranchTriggerHitTarget {
    static let longPressDuration: Double = 0.35
    static let hoverBridgePadding: CGFloat = 12
    static let userButtonOutsideOffset: CGFloat = 48
    static let assistantButtonOutsideOffset: CGFloat = 28
    static let buttonVerticalOffset: CGFloat = 2
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
                onSend: onSend
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

    @FocusState private var isComposerFocused: Bool

    private var canSend: Bool {
        !branch.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !branch.isGenerating
    }

    private var shouldShowPrimaryAction: Bool {
        branch.isGenerating ||
        !branch.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        focusMembrane
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    isComposerFocused = true
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
            primaryBranchComposer
        }
    }

    private var primaryBranchComposer: some View {
        HStack(spacing: 12) {
            branchTextField

            if shouldShowPrimaryAction {
                branchPrimaryActionButton
                    .transition(.scale(scale: 0.72, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(
            .timingCurve(0.68, -0.6, 0.32, 1.6, duration: 0.42),
            value: shouldShowPrimaryAction
        )
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
            NativeGlassPanel(
                cornerRadius: TemporaryBranchMembraneStyle.primaryComposerCornerRadius,
                tintColor: AppColor.controlGlassTint
            ) { EmptyView() }
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: TemporaryBranchMembraneStyle.primaryComposerCornerRadius,
                style: .continuous
            )
            .stroke(AppColor.panelStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
    }

    private var branchPrimaryActionButton: some View {
        Button(action: onSend) {
            Image(systemName: branch.isGenerating ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    ZStack {
                        Circle()
                            .fill(AppColor.colaOrange.opacity(canSend ? 0.92 : 0.28))

                        NativeGlassPanel(
                            cornerRadius: 18,
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
        record.memoryCandidates.filter { $0.scope != .ignore }
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
            return "Save to Project"
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
            return "Saved to Project Memory"
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

            VStack(alignment: .leading) {
                Text(text)
                    .font(.system(size: 14, weight: .regular))
                    .lineSpacing(6)
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
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
                .frame(width: 28, height: 28)
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
