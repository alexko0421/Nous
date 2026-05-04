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
    private static let collapsedPanelSize = NSSize(width: 420, height: 178)
    private static let summaryPanelSize = NSSize(width: 624, height: 504)

    private weak var voiceController: VoiceCommandController?
    private let focusObserver: VoiceMainWindowFocusObserver
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var appActivationObservers: [NSObjectProtocol] = []
    private var screenChangeObserver: NSObjectProtocol?
    private var spaceChangeObserver: NSObjectProtocol?
    private var hideTask: Task<Void, Never>?
    private var lastVoiceActive = false

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
        if voiceController?.isActive == true {
            lastVoiceActive = true
        }
        // Force the focus observer to re-evaluate live AppKit state right
        // now — without waiting for its debounce or for window/app
        // notifications. macOS does not reliably fire didBecomeKey /
        // didBecomeActive when returning to the Space that already owns
        // the main window, so the cached value can be stale at this
        // instant.
        focusObserver.forceRecomputeNow()
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
            _ = voiceController?.summaryPreview
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
        if voiceController.isActive != lastVoiceActive {
            lastVoiceActive = voiceController.isActive
            if voiceController.isActive {
                focusObserver.forceRecomputeNow()
            }
        }
        recomputeSurface(
            isActive: voiceController.isActive,
            isMainWorkspaceActive: Self.isMainWorkspaceActive(
                appActive: NSApp?.isActive ?? false,
                focusObserverActive: focusObserver.isMainWindowKey
            )
        )
    }

    private func recomputeSurface(
        isActive: Bool,
        isMainWorkspaceActive: Bool
    ) {
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
        } else if next == .notch {
            repositionPanel()
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

    static func notchPanelFrame(
        screenFrame: NSRect,
        safeAreaTop: CGFloat,
        hasSummaryPreview: Bool
    ) -> NSRect {
        let baseSize = hasSummaryPreview ? summaryPanelSize : collapsedPanelSize
        let width = min(baseSize.width, screenFrame.width)
        let height = min(max(baseSize.height, safeAreaTop + 104), screenFrame.height)

        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    private func applySurface(_ surface: VoiceCapsuleSurface) {
        switch surface {
        case .none:
            // Pass mouse events through so menu bar works normally
            panel?.ignoresMouseEvents = true
            hideTask?.cancel()
            hideTask = Task { @MainActor [weak self] in
                // Give the SwiftUI shrink animation time to finish before
                // destroying the window and resetting display state.
                // The 420ms matches the spring(response:0.38) settle time.
                try? await Task.sleep(nanoseconds: 420_000_000)
                guard !Task.isCancelled else { return }
                // Reset display state NOW (after animation) so the capsule
                // content doesn't vanish before the closing animation ends.
                self?.voiceController?.status = .idle
                self?.voiceController?.subtitleText = ""
                self?.hidePanel()
            }
        case .inWindow:
            // The in-window capsule in ChatArea takes over — hide the notch
            // panel immediately (no animation delay needed; the in-window
            // capsule is already visible). This prevents both surfaces from
            // appearing simultaneously when the user brings the window back.
            panel?.ignoresMouseEvents = true
            hideTask?.cancel()
            hidePanel()
        case .notch:
            hideTask?.cancel()
            showPanel()
            // Capture mouse events when expanded
            panel?.ignoresMouseEvents = false
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

    private var hostingView: NotchHostingView?

    private func createPanel(voiceController: VoiceCommandController) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        Self.configureForNotchOverlay(panel)
        panel.ignoresMouseEvents = true

        // NotchHostingView overrides safeAreaInsets → zero so SwiftUI content
        // truly starts at y = 0 (= screen top). No extra menu-bar inset applied.
        let host = NotchHostingView(rootView: NotchPanelRoot(voiceController: voiceController, bezelInset: 32))
        host.autoresizingMask = [.width, .height]
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
        let bezel = max(screen.safeAreaInsets.top, 32)

        let windowFrame = Self.notchPanelFrame(
            screenFrame: screen.frame,
            safeAreaTop: bezel,
            hasSummaryPreview: voiceController?.summaryPreview != nil
        )
        panel.setFrame(windowFrame, display: true)

        if let vc = voiceController {
            hostingView?.rootView = NotchPanelRoot(voiceController: vc, bezelInset: bezel)
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

// MARK: - NotchHostingView: zeroes safe area so SwiftUI fills to screen top

private final class NotchHostingView: NSHostingView<NotchPanelRoot> {
    // Override to report zero insets — prevents macOS from pushing SwiftUI
    // content down by the menu-bar height inside a borderless overlay panel.
    override var safeAreaInsets: NSEdgeInsets { .init() }
}

// MARK: - SwiftUI Notch Root

private struct NotchPanelRoot: View {
    @Bindable var voiceController: VoiceCommandController
    let bezelInset: CGFloat

    var body: some View {
        let isExpanded = voiceController.visibleSurface == .notch
        let hasSummary = voiceController.summaryPreview != nil
        // Capsule width: 380 base, 560 when summary card is visible
        let capsuleW: CGFloat = hasSummary ? 560 : 380

        ZStack(alignment: .top) {
            VStack(spacing: 10) {
                if isExpanded {
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
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 14)
                    .background(
                        NativeGlassPanel(cornerRadius: 36, tintColor: AppColor.controlGlassTint) { EmptyView() }
                            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
                    )
                    .overlay(
                        Capsule()
                            .stroke(AppColor.panelStroke.opacity(0.6), lineWidth: 1)
                    )

                    if let summaryPreview = voiceController.summaryPreview {
                        VStack(spacing: 8) {
                            VoiceSummarySeparator()
                            VoiceSummaryPaper(
                                preview: summaryPreview,
                                onDismiss: voiceController.dismissSummaryPreview
                            )
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .frame(width: capsuleW)
            // Only the pill itself responds to taps / buttons
            .contentShape(Rectangle())
            .onTapGesture { NotchPanelActivator.activate() }
            .padding(.top, bezelInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: isExpanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: voiceController.summaryPreview)
    }
}

private enum NotchPanelActivator {
    @MainActor static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        let candidate = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isExcludedFromWindowsMenu })
        if let window = candidate {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.unhide(nil)
        }
    }
}
