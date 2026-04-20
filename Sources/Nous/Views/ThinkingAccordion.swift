import SwiftUI

struct ThinkingAccordion: View {
    let content: String
    let isStreaming: Bool

    @State private var isExpanded: Bool = false

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
