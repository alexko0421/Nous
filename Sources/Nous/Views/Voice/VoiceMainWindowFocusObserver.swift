import AppKit
import Combine

extension Notification.Name {
    static let nousMainWindowConfigured = Notification.Name("nousMainWindowConfigured")
}

/// Publishes whether Nous's main window is currently the user's active workspace.
///
/// Used by `VoiceNotchPanelController` to decide whether the in-window capsule
/// or the notch capsule should be visible. Signal expression chosen by Spike D:
/// track the actual SwiftUI content window and ignore auxiliary overlay panels.
/// Debounce window of 120ms suppresses Cmd-Tab flicker.
@MainActor
final class VoiceMainWindowFocusObserver: ObservableObject {
    @Published private(set) var isMainWindowKey: Bool = false

    private weak var trackedMainWindow: NSWindow?
    private var notificationObservers: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private let debounceMillis: UInt64 = 120

    init() {
        recompute()
        let nc = NotificationCenter.default
        let triggers: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification
        ]
        for name in triggers {
            let observer = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRecompute()
                }
            }
            notificationObservers.append(observer)
        }

        // NSWorkspace fires didActivateApplication for every cross-app focus
        // change (including Nous coming to / leaving the front). This is the
        // most reliable signal for cross-window/app switching — more reliable
        // than NSApplication.didBecomeActive which sometimes lags or doesn't
        // fire when the same app's other windows are involved.
        let wsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.forceRecomputeNow()
            }
        }
        notificationObservers.append(wsObserver)

        let windowObserver = nc.addObserver(
            forName: .nousMainWindowConfigured,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self] in
                self?.trackMainWindow(window)
            }
        }
        notificationObservers.append(windowObserver)
    }

    deinit {
        debounceTask?.cancel()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func trackMainWindow(_ window: NSWindow) {
        guard trackedMainWindow !== window else {
            scheduleRecompute()
            return
        }
        trackedMainWindow = window
        scheduleRecompute()
    }

    static func isTrackedMainWindowActive(
        appActive: Bool,
        isVisible: Bool,
        isMiniaturized: Bool,
        isKeyWindow: Bool,
        isMainWindow: Bool
    ) -> Bool {
        // The user is "in-window" only when Nous is the frontmost app and
        // its main window isn't sitting in the Dock. We deliberately do
        // NOT consult `isVisible` — its cross-Space semantics on macOS
        // make the value flip in confusing ways (see the inverted-surface
        // dogfood report) and our `appActive` check (driven by
        // NSWorkspace.frontmostApplication) already covers the case where
        // Nous is on a different Space than the user, because in that
        // case some other app is frontmost.
        appActive && !isMiniaturized
    }

    private func scheduleRecompute() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.debounceMillis ?? 120) * 1_000_000)
            await MainActor.run { self?.recompute() }
        }
    }

    /// Synchronously re-evaluates the focus state without going through
    /// the debounce. Use this after Space switches when notifications may
    /// not fire reliably and the cached value may be stale.
    func forceRecomputeNow() {
        debounceTask?.cancel()
        recompute()
    }

    private func recompute() {
        // Query NSWorkspace's frontmost app instead of NSApp.isActive.
        // NSApp.isActive can be stale at notification fire time (race
        // window between AppKit dispatching the notification and updating
        // the cached active flag), which caused inverted in-window/notch
        // behavior on focus changes. NSWorkspace.frontmostApplication is
        // OS-level and stable.
        let myPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let appActive = (frontPID == myPID)
        let main = trackedMainWindow ?? NSApp?.mainWindow
        let isKey = Self.isTrackedMainWindowActive(
            appActive: appActive,
            isVisible: main?.isVisible ?? false,
            isMiniaturized: main?.isMiniaturized ?? false,
            isKeyWindow: main?.isKeyWindow ?? false,
            isMainWindow: main?.isMainWindow ?? false
        )
        if isKey != isMainWindowKey {
            isMainWindowKey = isKey
        }
    }
}
