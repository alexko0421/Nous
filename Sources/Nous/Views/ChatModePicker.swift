import SwiftUI

struct ChatModePicker: View {
    let selectedMode: ChatMode
    let onSelect: (ChatMode) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ChatMode.allCases, id: \.rawValue) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 11, weight: .medium))
                        Text(mode.label)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(mode == selectedMode ? .white : AppColor.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(mode == selectedMode ? AppColor.colaOrange : AppColor.surfaceSecondary)
                    )
                    .overlay(
                        Capsule()
                            .stroke(mode == selectedMode ? Color.white.opacity(0.16) : AppColor.panelStroke, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
