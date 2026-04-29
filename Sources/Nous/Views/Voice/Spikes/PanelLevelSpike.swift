#if DEBUG
import AppKit
import SwiftUI

/// Spike A — Panel Level + Z-Order.
///
/// Scratch harness used to determine the right `NSWindow.Level` for the upcoming
/// voice notch capsule. Alex runs this on a Mac with a built-in notch and fills in
/// the matrix at `docs/superpowers/spikes/2026-04-29-spike-a-panel-level.md`.
///
/// This file is intentionally throwaway — it gets deleted in Phase 1.5 of the
/// voice notch capsule plan. Do not depend on this from production code.
@MainActor
final class PanelLevelSpike {
    static let shared = PanelLevelSpike()

    private var panel: NSPanel?

    func show(level: NSWindow.Level, label: String) {
        // Replace any existing spike panel so cycling levels is one-click.
        hide()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = NSColor(white: 0, alpha: 0.85)
        panel.hasShadow = false

        let host = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text("Spike A · close from Debug menu")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        )
        panel.contentView = host

        if let screen = NSScreen.main {
            let frame = NSRect(
                x: screen.frame.midX - 160,
                y: screen.frame.maxY - 100,
                width: 320,
                height: 80
            )
            panel.setFrame(frame, display: true)
        }
        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Stable identifiers for the five window levels Alex needs to cycle through.
/// Kept as a top-level enum so a SwiftUI menu can iterate them.
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
