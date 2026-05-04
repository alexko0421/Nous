import SwiftUI
import AppKit

struct VoiceCapsuleView: View {
    let status: VoiceModeStatus
    let subtitleText: String
    let audioLevel: Float
    let hasPendingConfirmation: Bool
    let summaryPreview: VoiceSummaryPreview?
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onDismissSummary: () -> Void

    var body: some View {
        VStack(spacing: 10) {
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
                NativeGlassPanel(cornerRadius: 36, tintColor: AppColor.controlGlassTint) { EmptyView() }
                    .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
            )
            .overlay(
                Capsule()
                    .stroke(AppColor.panelStroke.opacity(0.6), lineWidth: 1)
            )

            if let summaryPreview {
                VStack(spacing: 8) {
                    VoiceSummarySeparator()
                    VoiceSummaryPaper(preview: summaryPreview, onDismiss: onDismissSummary)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: summaryPreview)
    }
}

struct VoiceSummarySeparator: View {
    var body: some View {
        Capsule()
            .fill(AppColor.panelStroke.opacity(0.95))
            .frame(width: 440, height: 1)
            .accessibilityHidden(true)
    }
}

struct VoiceSummaryPaper: View {
    let preview: VoiceSummaryPreview
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Text(preview.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(AppColor.colaDarkText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AppColor.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss summary")
                .accessibilityLabel("Dismiss summary")
            }

            ScrollView {
                ChatMarkdownView(segments: ChatMarkdownRenderer.parse(preview.markdown))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .frame(width: 480, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 22, x: 0, y: 12)
        .environment(\.colorScheme, .light)
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
                        : AppColor.controlGlassTint
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
