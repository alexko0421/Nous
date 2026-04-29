#if DEBUG
import AppKit
import SwiftUI

/// Spike A+B+C — Panel Level + Top Clipping + Notch Detection.
///
/// Combined harness used to determine the right `NSWindow.Level` for the upcoming
/// voice notch capsule, while also visually validating the top-clipping technique
/// and notch-screen detection. Alex runs this on a Mac with a built-in notch and
/// fills in the matrix at `docs/superpowers/spikes/2026-04-29-spike-a-panel-level.md`.
///
/// The three spikes were merged because z-order test results are only meaningful
/// when the panel is positioned and rendered correctly. Visual fidelity of this
/// harness is intentionally close to the final design.
///
/// `PanelLevelSpike.swift` is `#if DEBUG`-gated and scheduled for deletion in
/// Phase 1 Task 1.5. `NotchScreenDetection.swift` is NOT spike scratch — it's
/// promoted to permanent and used by Phase 3.
@MainActor
final class PanelLevelSpike {
    static let shared = PanelLevelSpike()
    private var panel: NSPanel?

    func show(level: NSWindow.Level, label: String) {
        // Replace any existing spike panel so cycling levels is one-click.
        hide()

        let notchScreen = NotchScreenDetection.currentNotchScreen()
        guard let screen = notchScreen ?? NSScreen.main else {
            print("[PanelLevelSpike] No screen available")
            return
        }
        if notchScreen == nil {
            print("[PanelLevelSpike] WARNING: No notch screen detected; falling back to NSScreen.main (\(screen.localizedName))")
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        // Liquid Glass backdrop (NSVisualEffectView) hosts the SwiftUI capsule.
        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.clear.cgColor

        let host = NSHostingView(rootView: PanelLevelSpikeContent(label: label))
        host.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(backdrop)
        container.addSubview(host)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container

        // Position: top 36pt sits above the safe area (above the notch bezel),
        // 64pt visible below the notch.
        let safeTopY = screen.frame.maxY - screen.safeAreaInsets.top
        let frame = NSRect(
            x: screen.frame.midX - 180,
            y: safeTopY - 64,
            width: 360,
            height: 100
        )
        panel.setFrame(frame, display: true)
        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct PanelLevelSpikeContent: View {
    let label: String

    var body: some View {
        VStack(spacing: 0) {
            // Top 36pt — masked by hardware notch.
            Spacer().frame(height: 36)

            HStack(spacing: 12) {
                // Waveform placeholder (real bars come in Phase 1.5).
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColor.colaOrange.opacity(0.6))
                    .frame(width: 27, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Listening")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppColor.colaDarkText)
                    Text(label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(AppColor.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotchCapsuleBackground())
    }
}

private struct NotchCapsuleBackground: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Color.white.opacity(0.42)
        }
        .clipShape(NotchCapsuleShape(cornerRadius: 24))
        .overlay(
            NotchCapsuleShape(cornerRadius: 24)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
        .shadow(
            color: Color(red: 120/255, green: 80/255, blue: 40/255).opacity(0.20),
            radius: 18, x: 0, y: 16
        )
    }
}

/// Sharp top corners (hidden behind notch), 24pt rounded bottom corners.
/// Top edge has no stroke either — the overlay path skips it via `closeSubpath`
/// over the rectangular top, but the visible portion of the top edge is occluded
/// by the hardware notch so the visual contract is preserved.
private struct NotchCapsuleShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Sharp top corners.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Right edge down to corner radius.
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        // Bottom-right rounded corner.
        p.addArc(
            center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        // Bottom edge.
        p.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        // Bottom-left rounded corner.
        p.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

/// Stable identifiers for the five window levels Alex needs to cycle through.
enum PanelLevelSpikeCase: String, CaseIterable, Identifiable {
    case normal
    case floating
    case statusBar
    case popUpMenu
    case modalPanel

    var id: String { rawValue }

    var level: NSWindow.Level {
        switch self {
        case .normal:     return .normal
        case .floating:   return .floating
        case .statusBar:  return .statusBar
        case .popUpMenu:  return .popUpMenu
        case .modalPanel: return .modalPanel
        }
    }

    var label: String {
        switch self {
        case .normal:     return ".normal"
        case .floating:   return ".floating"
        case .statusBar:  return ".statusBar"
        case .popUpMenu:  return ".popUpMenu"
        case .modalPanel: return ".modalPanel"
        }
    }
}
#endif
