import SwiftUI
import AppKit

struct VoiceCapsuleView: View {
    let status: VoiceModeStatus
    let subtitleText: String
    let audioLevel: Float
    let hasPendingConfirmation: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VoiceCapsuleContent(
            status: status,
            subtitleText: subtitleText,
            audioLevel: audioLevel,
            hasPendingConfirmation: hasPendingConfirmation,
            showsStopButton: false, // in-window relies on VoiceModeButton for start/stop
            onConfirm: onConfirm,
            onCancel: onCancel,
            onStop: {} // no-op; not shown in-window
        )
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
