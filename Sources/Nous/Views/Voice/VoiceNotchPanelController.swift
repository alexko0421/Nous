// Sources/Nous/Views/Voice/VoiceNotchPanelController.swift
import AppKit
import SwiftUI
import Combine

/// Hosts the Liquid Glass notch capsule in a borderless `NSPanel` that floats
/// at the status-bar level and tracks `VoiceCommandController.visibleSurface`.
///
/// Owns the panel lifecycle, frame positioning across screen-parameter changes,
/// and the bridge between the @Observable controller and the AppKit window.
/// Observation uses `withObservationTracking` (re-armed in `onChange`) because
/// `@Observable` types are not Combine publishers; the focus observer is
/// observed via Combine because it is an `ObservableObject`.
@MainActor
final class VoiceNotchPanelController {
    private weak var voiceController: VoiceCommandController?
    private let focusObserver: VoiceMainWindowFocusObserver
    private var panel: NSPanel?
    private var hostingView: NSHostingView<NotchPanelRoot>?
    private var cancellables = Set<AnyCancellable>()
    private var screenChangeObserver: NSObjectProtocol?

    init(
        voiceController: VoiceCommandController,
        focusObserver: VoiceMainWindowFocusObserver
    ) {
        self.voiceController = voiceController
        self.focusObserver = focusObserver
        bind()
    }

    deinit {
        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func bind() {
        guard voiceController != nil else { return }

        // `@Observable` types are observed via `withObservationTracking`, not Combine.
        // Re-arm the tracking on every change so we keep observing.
        observeVoiceState()

        // The focus observer is an ObservableObject (Combine), so $isMainWindowKey works.
        focusObserver.$isMainWindowKey
            .sink { [weak self] _ in self?.recomputeFromCurrentState() }
            .store(in: &cancellables)

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionPanel()
            }
        }
    }

    private func observeVoiceState() {
        withObservationTracking {
            // Touch the properties we care about so the tracker registers them.
            _ = voiceController?.isActive
            _ = voiceController?.pendingAction
        } onChange: { [weak self] in
            // onChange fires off the main actor; hop back before mutating UI.
            Task { @MainActor [weak self] in
                self?.recomputeFromCurrentState()
                // Re-arm — withObservationTracking is one-shot.
                self?.observeVoiceState()
            }
        }
    }

    private func recomputeFromCurrentState() {
        guard let voiceController else { return }
        recomputeSurface(
            isActive: voiceController.isActive,
            isKey: focusObserver.isMainWindowKey
        )
    }

    private func recomputeSurface(isActive: Bool, isKey: Bool) {
        guard let voiceController else { return }
        // Frozen surface during pending confirmation (codex finding #6)
        if voiceController.pendingAction != nil { return }

        let next: VoiceCapsuleSurface
        if !isActive {
            next = .none
        } else if isKey {
            next = .inWindow
        } else if NotchScreenDetection.currentNotchScreen() != nil {
            next = .notch
        } else {
            next = .inWindow // notch-less fallback per spec § 6
        }
        if voiceController.visibleSurface != next {
            voiceController.visibleSurface = next
            applySurface(next)
        }
    }

    private func applySurface(_ surface: VoiceCapsuleSurface) {
        switch surface {
        case .none, .inWindow:
            hidePanel()
        case .notch:
            showPanel()
        }
    }

    private func showPanel() {
        guard let voiceController, let screen = NotchScreenDetection.currentNotchScreen() else {
            return
        }
        if panel == nil {
            createPanel(voiceController: voiceController)
        }
        positionPanel(on: screen)
        panel?.orderFront(nil)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func createPanel(voiceController: VoiceCommandController) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Level chosen by Spike A (skipped; verify in Phase 6 QA).
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        let host = NSHostingView(rootView: NotchPanelRoot(voiceController: voiceController))
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host
        self.hostingView = host
        self.panel = panel
    }

    private func positionPanel(on screen: NSScreen) {
        guard let panel else { return }
        // Technique chosen by Spike B: option (a) — top 36pt sits above the
        // safe area and is physically masked by the hardware notch.
        let safeTopY = screen.frame.maxY - screen.safeAreaInsets.top
        let width: CGFloat = 360
        let height: CGFloat = 100
        let frame = NSRect(
            x: screen.frame.midX - width/2,
            y: safeTopY - (height - 36),
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
    }

    private func repositionPanel() {
        if let screen = NotchScreenDetection.currentNotchScreen() {
            positionPanel(on: screen)
        } else {
            hidePanel()
        }
    }
}

private struct NotchPanelRoot: View {
    @Bindable var voiceController: VoiceCommandController

    var body: some View {
        VStack(spacing: 0) {
            // Top 36pt sits behind the bezel and is masked by the hardware notch.
            Spacer().frame(height: 36)

            VoiceCapsuleContent(
                status: voiceController.status,
                subtitleText: voiceController.subtitleText,
                audioLevel: voiceController.audioLevel,
                hasPendingConfirmation: voiceController.pendingAction != nil,
                showsStopButton: true,
                onConfirm: voiceController.confirmPendingAction,
                onCancel: voiceController.cancelPendingAction,
                onStop: voiceController.stop
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(NotchCapsuleBackground())
            .frame(maxWidth: 520) // Total capsule width cap (codex finding #14)
            .allowsHitTesting(voiceController.visibleSurface == .notch)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct NotchCapsuleBackground: View {
    var body: some View {
        ZStack {
            // Liquid Glass material (mapping from spec § 1)
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

/// Sharp top corners (the top is masked by the notch), 24pt rounded bottom corners.
private struct NotchCapsuleShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerRadius))
        p.addArc(
            center: CGPoint(x: rect.maxX - cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        p.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        p.closeSubpath()
        return p
    }
}
