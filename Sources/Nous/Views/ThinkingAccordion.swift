import SwiftUI

struct ThinkingAccordion: View {
    let content: String
    let isStreaming: Bool
    let startedAt: Date?

    @State private var isExpanded: Bool
    private let motion = DisclosurePillMotion()

    init(content: String, isStreaming: Bool, startedAt: Date? = nil) {
        self.content = content
        self.isStreaming = isStreaming
        self.startedAt = startedAt
        // 如果一出世就系 Streaming 状态，预设展开
        self._isExpanded = State(initialValue: isStreaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: motion.contentSpacing(isExpanded: isExpanded)) {
            pill
                .zIndex(1)

            DisclosurePillContent(isExpanded: isExpanded, motion: motion) {
                contentText
            }
        }
        .onChange(of: isStreaming) { _, newValue in
            // 当停止 Streaming (开始输出最终答案) 时，自动折叠
            if !newValue && isExpanded {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded = false
                }
            }
        }
        // 当文字内容增加导致高度变动时，平滑撑开而唔系突然跳动
        .animation(.easeOut(duration: 0.15), value: content)
    }

    private var contentText: some View {
        Text(content)
            .font(.system(size: 12))
            .foregroundStyle(AppColor.secondaryText)
            .lineSpacing(3)
            .textSelection(.enabled)
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pill: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                FrameSpinner(isAnimating: isStreaming)
                title
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(AppColor.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(AppColor.subtleFill)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var title: some View {
        if isStreaming, let startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(Self.titleText(isStreaming: isStreaming, startedAt: startedAt, now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(AppColor.secondaryText)
            }
        } else {
            Text(Self.titleText(isStreaming: isStreaming, startedAt: startedAt, now: Date()))
                .font(.system(size: 11))
                .foregroundStyle(AppColor.secondaryText)
        }
    }

    static func titleText(isStreaming: Bool, startedAt: Date?, now: Date) -> String {
        guard isStreaming else { return "Thinking" }
        guard let startedAt else { return "Thinking…" }
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        return "Thinking for \(elapsed)s"
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        ThinkingAccordion(
            content: "Let me think about this carefully...\n\nThe user is asking about X, which requires Y.",
            isStreaming: true
        )
        ThinkingAccordion(
            content: "Finished reasoning. Here is the trace of what I considered.",
            isStreaming: false
        )
    }
    .padding(40)
    .background(AppColor.colaBeige)
}
