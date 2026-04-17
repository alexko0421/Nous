import SwiftUI

struct ThinkingDisclosure: View {
    let text: String
    let seconds: Double?
    let isLive: Bool

    @State private var isExpanded: Bool = false
    @State private var pulse: Bool = false

    private var titleText: String {
        if isLive {
            return "諗緊..."
        }
        if let s = seconds, s >= 0.1 {
            return String(format: "已思考 %.1fs", s)
        }
        return "已思考"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                guard !isLive, !text.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    if isLive {
                        Circle()
                            .fill(AppColor.colaOrange)
                            .frame(width: 6, height: 6)
                            .opacity(pulse ? 1.0 : 0.35)
                    } else {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(AppColor.colaDarkText.opacity(0.55))
                    }
                    Text(titleText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText.opacity(0.55))
                }
            }
            .buttonStyle(.plain)
            .disabled(isLive || text.isEmpty)
            .accessibilityLabel(Text(isLive ? "Nous 正在思考" : "展开思考过程"))

            if isExpanded && !text.isEmpty {
                Text(text)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.6))
                    .lineSpacing(3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColor.colaDarkText.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .onAppear {
            guard isLive else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                pulse.toggle()
            }
        }
    }
}
