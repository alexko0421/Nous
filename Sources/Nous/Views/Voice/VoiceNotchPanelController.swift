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
    private var appActivationObservers: [NSObjectProtocol] = []
    private var screenChangeObserver: NSObjectProtocol?
    private var spaceChangeObserver: NSObjectProtocol?

    init(
        voiceController: VoiceCommandController,
        focusObserver: VoiceMainWindowFocusObserver
    ) {
        self.voiceController = voiceController
        self.focusObserver = focusObserver
        bind()
    }

    deinit {
        for observer in appActivationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
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

        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            let observer = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recomputeFromCurrentState()
                }
            }
            appActivationObservers.append(observer)
        }

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.repositionPanel()
            }
        }

        // Re-show the panel after Space switches. .canJoinAllSpaces alone is not
        // always enough — switching Spaces can drop the panel from the visible
        // stack on the new active Space, especially after the app's main window
        // changes spaces. Kick orderFront on every space change while the
        // surface is supposed to be the notch.
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSpaceChange()
            }
        }
    }

    private func handleSpaceChange() {
        // Recompute first — the new Space may flip the focus observer.
        recomputeFromCurrentState()
        // Then kick orderFront unconditionally if we should be on notch.
        // Even when visibleSurface didn't change, switching Spaces can drop
        // the panel from the active Space's window stack; orderFront
        // re-mounts it.
        if voiceController?.visibleSurface == .notch {
            showPanel()
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
            isMainWorkspaceActive: Self.isMainWorkspaceActive(
                appActive: NSApp?.isActive ?? false,
                focusObserverActive: focusObserver.isMainWindowKey
            )
        )
    }

    private func recomputeSurface(isActive: Bool, isMainWorkspaceActive: Bool) {
        guard let voiceController else { return }
        let next = VoiceCapsuleSurfacePolicy.nextSurface(
            isVoiceActive: isActive,
            hasPendingAction: voiceController.pendingAction != nil,
            currentSurface: voiceController.visibleSurface,
            isMainWorkspaceActive: isMainWorkspaceActive,
            hasNotchScreen: NotchScreenDetection.currentNotchScreen() != nil
        )
        if voiceController.visibleSurface != next {
            voiceController.visibleSurface = next
            applySurface(next)
        }
    }

    static func isMainWorkspaceActive(appActive: Bool, focusObserverActive: Bool) -> Bool {
        // Use the strict focus signal only. `appActive` (NSApp.isActive)
        // remains true when Nous is the frontmost app even if its main
        // window is on a different Space — that's the wrong moment to
        // pretend we're "in-window". The focusObserver signal already
        // bundles appActive && mainKey && !miniaturized, which is what
        // we actually want.
        focusObserverActive
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
        panel?.orderFrontRegardless()
        panel?.orderFront(nil)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func createPanel(voiceController: VoiceCommandController) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // popUpMenu sits above .statusBar / .floating / menu bar but below
        // Spotlight, Control Center, and modal panels — the right slot for
        // a notch overlay that should never be obscured by ordinary app
        // chrome but must defer to system-modal UI.
        panel.level = .popUpMenu
        Self.configureForNotchOverlay(panel)

        let host = NSHostingView(rootView: NotchPanelRoot(voiceController: voiceController, bezelInset: 36))
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host
        self.hostingView = host
        self.panel = panel
    }

    static func configureForNotchOverlay(_ panel: NSPanel) {
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
    }

    private func positionPanel(on screen: NSScreen) {
        guard let panel else { return }
        // Position the panel so its top edge is at the absolute top of the
        // screen, extending into the bezel/notch area. The SwiftUI Spacer
        // at the top of NotchPanelRoot uses the screen's actual
        // safeAreaInsets.top to absorb the bezel height (~32pt on 14"
        // M-series, ~38-40pt on 16" / Pro Display XDR, etc.) so the
        // visible Liquid Glass capsule's top edge sits flush with the
        // bezel boundary on every notched Mac.
        let bezel = max(screen.safeAreaInsets.top, 32)
        let width: CGFloat = 360
        let visibleCapsuleHeight: CGFloat = 74 // 12pt padding + content + 12pt padding (~50pt content)
        let totalHeight = bezel + visibleCapsuleHeight
        let frame = NSRect(
            x: screen.frame.midX - width/2,
            y: screen.frame.maxY - totalHeight,
            width: width,
            height: totalHeight
        )
        panel.setFrame(frame, display: true)

        // Re-host with the right bezel inset so the spacer matches this screen.
        if let voiceController {
            hostingView?.rootView = NotchPanelRoot(voiceController: voiceController, bezelInset: bezel)
        }
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
    let bezelInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // The top `bezelInset` sits behind the hardware notch / bezel
            // and is physically masked. Computed from the live screen's
            // safeAreaInsets.top so the capsule sits flush with the bezel
            // boundary on every notched Mac.
            Spacer().frame(height: bezelInset)

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
            .contentShape(NotchCapsuleShape(cornerRadius: 24))
            .onTapGesture {
                Self.activateNousMainWindow()
            }
            .allowsHitTesting(voiceController.visibleSurface == .notch)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Brings Nous's main window to the front. SwiftUI `Button { }` calls
    /// inside `VoiceCapsuleContent` (Stop / Confirm / Cancel) consume taps
    /// before they reach this gesture, so action regions don't activate.
    /// If the main window was closed (app persists via NousAppDelegate),
    /// `applicationShouldHandleReopen` will recreate it on activation.
    @MainActor
    static func activateNousMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Find the SwiftUI WindowGroup window and bring it forward.
        let candidate = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isExcludedFromWindowsMenu })
        if let window = candidate {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            // No SwiftUI window currently exists — let AppKit's reopen path
            // recreate it. NSApp.activate above triggers
            // applicationShouldHandleReopen which reopens the WindowGroup.
            NSApp.unhide(nil)
        }
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
