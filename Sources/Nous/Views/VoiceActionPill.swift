import SwiftUI
import AppKit

struct VoiceCapsuleView: View {
    let status: VoiceModeStatus
    let hasPendingConfirmation: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            FrameSpinner(isAnimating: status == .listening || status == .thinking)
                .frame(width: 16, height: 16)

            Text(status.displayText)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColor.colaDarkText)
                .tracking(0.5) // Cinematic letter spacing
                .lineLimit(1)
                .contentTransition(.interpolate)
                .animation(.easeOut(duration: 0.15), value: status.displayText)

            if hasPendingConfirmation {
                HStack(spacing: 8) {
                    Button("Confirm", action: onConfirm)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColor.colaOrange)

                    Button("Cancel", action: onCancel)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColor.secondaryText)
                }
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            NativeGlassPanel(cornerRadius: 24, tintColor: AppColor.glassTint) { EmptyView() }
                .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        )
        .overlay(
            Capsule()
                .stroke(AppColor.panelStroke.opacity(0.6), lineWidth: 1)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: status.displayText)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: hasPendingConfirmation)
    }
}

struct VoiceModeButton: View {
    let isActive: Bool
    let unavailableReason: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                NativeGlassPanel(
                    cornerRadius: 18,
                    tintColor: isActive
                        ? NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.22)
                        : AppColor.glassTint
                ) { EmptyView() }

                Image(systemName: isActive ? "mic.fill" : "mic")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isActive ? AppColor.colaOrange : AppColor.secondaryText)
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            .contentShape(Circle())
            .overlay(Circle().stroke(AppColor.panelStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(isActive ? "Stop Voice Mode" : (unavailableReason ?? "Start Voice Mode"))
    }
}
