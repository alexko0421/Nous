// Sources/Nous/Views/Voice/VoiceCapsuleContent.swift
import SwiftUI

/// Shared body of the voice capsule. Used by both `VoiceCapsuleView` (in-window)
/// and `VoiceNotchPanelController` (notch panel). Owns no state; consumers wrap
/// it in chrome and pass behavior in.
struct VoiceCapsuleContent: View {
    let status: VoiceModeStatus
    let subtitleText: String
    let audioLevel: Float
    let hasPendingConfirmation: Bool
    let showsStopButton: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onStop: () -> Void

    private var barState: VoiceWaveformBars.BarState {
        switch status {
        case .listening:                        return .listening
        case .thinking:                         return .thinking
        case .error:                            return .error
        case .idle, .action, .needsConfirmation: return .idle
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VoiceWaveformBars(level: audioLevel, state: barState)
                .frame(width: 27, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.displayText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColor.colaDarkText)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                    .animation(.easeOut(duration: 0.15), value: status.displayText)

                if !subtitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(subtitleText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(AppColor.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.interpolate)
                        .animation(.easeOut(duration: 0.12), value: subtitleText)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)

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
            } else if showsStopButton && shouldShowStopForStatus {
                StopButton(onTap: onStop)
                    .padding(.leading, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: status.displayText)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: subtitleText)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: hasPendingConfirmation)
    }

    private var shouldShowStopForStatus: Bool {
        // Stop covers all active states except needsConfirmation (codex #10)
        switch status {
        case .idle, .listening, .thinking, .action, .error: return true
        case .needsConfirmation: return false
        }
    }
}

private struct StopButton: View {
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(outerColor)
                    .background(.ultraThinMaterial, in: Circle())

                Circle()
                    .stroke(borderColor, lineWidth: 1)

                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color(red: 255/255, green: 225/255, blue: 220/255).opacity(0.95))
                    .frame(width: 13, height: 13)
            }
            .frame(width: 35, height: 35)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Stop voice mode")
        .accessibilityLabel("Stop voice mode")
    }

    private var outerColor: Color {
        let red = isHovering ? 235.0 : 225.0
        let green = isHovering ? 50.0 : 40.0
        let blue = isHovering ? 45.0 : 35.0
        let alpha = isHovering ? 0.82 : 0.72
        return Color(red: red/255, green: green/255, blue: blue/255).opacity(alpha)
    }

    private var borderColor: Color {
        let alpha = isHovering ? 0.65 : 0.55
        let r = isHovering ? 130.0 : 110.0
        let g = isHovering ? 120.0 : 100.0
        return Color(red: 255/255, green: r/255, blue: g/255).opacity(alpha)
    }
}
