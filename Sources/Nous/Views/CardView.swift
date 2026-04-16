import SwiftUI

struct CardView: View {
    let payload: CardPayload
    let onTapOption: (String) -> Void
    let onTapWriteOwn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !payload.framing.isEmpty {
                Text(payload.framing)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(AppColor.colaDarkText)
                    .lineSpacing(4)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }

            VStack(spacing: 8) {
                ForEach(payload.options, id: \.self) { option in
                    optionBubble(text: option) { onTapOption(option) }
                }
                optionBubble(text: "写下你的想法", isEscape: true) { onTapWriteOwn() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            .regular.tint(AppColor.colaOrange.opacity(0.18)),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }

    private func optionBubble(text: String, isEscape: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isEscape
                                     ? AppColor.colaDarkText.opacity(0.55)
                                     : AppColor.colaDarkText)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
            .overlay(Capsule().stroke(AppColor.colaDarkText.opacity(0.08), lineWidth: 1))
            .opacity(isEscape ? 0.72 : 1.0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isEscape ? "写下你的想法，打开输入框" : text))
    }
}

#Preview {
    CardView(
        payload: CardPayload(
            framing: "你问我呢个背后...",
            options: ["已经决定咗，想我 confirm", "Build 卡咗，想用 quit 推自己"]
        ),
        onTapOption: { print("option: \($0)") },
        onTapWriteOwn: { print("write own") }
    )
    .padding()
    .background(AppColor.colaBeige)
}
