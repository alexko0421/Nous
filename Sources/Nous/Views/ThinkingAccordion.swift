import SwiftUI

struct ThinkingAccordion: View {
    let content: String
    let isStreaming: Bool

    @State private var isExpanded: Bool

    init(content: String, isStreaming: Bool) {
        self.content = content
        self.isStreaming = isStreaming
        // 如果一出世就系 Streaming 状态，预设展开
        self._isExpanded = State(initialValue: isStreaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            pill
            if isExpanded {
                Text(content)
                    .font(.system(size: 12))
                    .foregroundStyle(AppColor.secondaryText)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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

    private var pill: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                FrameSpinner(isAnimating: isStreaming)
                Text(isStreaming ? "Thinking…" : "Thinking")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColor.secondaryText)
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
