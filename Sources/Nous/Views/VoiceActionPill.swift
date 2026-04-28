import SwiftUI

struct VoiceActionPill: View {
    let status: VoiceModeStatus
    let hasPendingConfirmation: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FrameSpinner(isAnimating: status == .listening || status == .thinking)
                .frame(width: 14, height: 14)

            Text(status.displayText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColor.colaDarkText)
                .lineLimit(1)

            if hasPendingConfirmation {
                Button("Confirm", action: onConfirm)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColor.colaOrange)

                Button("Cancel", action: onCancel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            NativeGlassPanel(cornerRadius: 18, tintColor: AppColor.glassTint) { EmptyView() }
        )
        .overlay(
            Capsule()
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
    }
}
