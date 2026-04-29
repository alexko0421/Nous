import AppKit
import Combine

/// Publishes whether Nous's main window is currently the user's active workspace.
///
/// Used by `VoiceNotchPanelController` to decide whether the in-window capsule
/// or the notch capsule should be visible. Signal expression chosen by Spike D:
/// `NSApp.isActive && NSApp.mainWindow.isKeyWindow && !mainWindow.isMiniaturized`.
/// Debounce window of 120ms suppresses Cmd-Tab flicker.
@MainActor
final class VoiceMainWindowFocusObserver: ObservableObject {
    @Published private(set) var isMainWindowKey: Bool = false

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
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification
        ]
        for name in triggers {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRecompute()
            }
        }
    }

    private func scheduleRecompute() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.debounceMillis ?? 120) * 1_000_000)
            await MainActor.run { self?.recompute() }
        }
    }

    private func recompute() {
        let appActive = NSApp?.isActive ?? false
        let main = NSApp?.mainWindow
        let mainKey = main?.isKeyWindow ?? false
        let miniaturized = main?.isMiniaturized ?? false

        let isKey = appActive && mainKey && !miniaturized
        if isKey != isMainWindowKey {
            isMainWindowKey = isKey
        }
    }
}
