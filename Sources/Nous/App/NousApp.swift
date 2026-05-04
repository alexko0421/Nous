import SwiftUI
import AppKit

@main
struct NousApp: App {
    @NSApplicationDelegateAdaptor(NousAppDelegate.self) private var appDelegate

    init() {
        WindowRestorationPolicy.disablePersistentWindowRestoration()
        guard !AppRuntimeContext.isRunningUnitTests else { return }
        Task { @MainActor in
            NousMainWindowLifecycle.shared.start()
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Keeps the app running after the main window is closed so that voice mode
/// and the notch capsule continue to function. Closing the main window now
/// hides Nous; clicking the dock icon brings it back.
@MainActor
final class NousAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard shouldRunMainWindowLifecycle else { return }
        NousMainWindowLifecycle.shared.start()
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        guard shouldRunMainWindowLifecycle else { return }
        NousMainWindowLifecycle.shared.recoverMainWindowIfNeeded()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard shouldRunMainWindowLifecycle else { return }
        NousMainWindowLifecycle.shared.recoverMainWindowIfNeeded()
    }

    func applicationDidUnhide(_ notification: Notification) {
        guard shouldRunMainWindowLifecycle else { return }
        NousMainWindowLifecycle.shared.recoverMainWindowIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard shouldRunMainWindowLifecycle else { return true }
        NousMainWindowLifecycle.shared.showMainWindow()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NousMainWindowLifecycle.shared.stop()
    }

    private var shouldRunMainWindowLifecycle: Bool {
        !AppRuntimeContext.isRunningUnitTests
    }
}

enum AppRuntimeContext {
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

@MainActor
final class NousMainWindowLifecycle {
    static let shared = NousMainWindowLifecycle()

    private var environment: AppEnvironment?
    private var mainWindowController: NousMainWindowController?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var appUpdateObserver: NSObjectProtocol?
    private var didStart = false

    func start() {
        if didStart {
            recoverMainWindowIfNeeded()
            return
        }

        didStart = true
        NSApp.setActivationPolicy(.regular)
        installMainWindowRecoveryObservers()
        showMainWindow()
    }

    func stop() {
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        if let appUpdateObserver {
            NotificationCenter.default.removeObserver(appUpdateObserver)
        }
        workspaceActivationObserver = nil
        appUpdateObserver = nil
        didStart = false
    }

    private func installMainWindowRecoveryObservers() {
        guard workspaceActivationObserver == nil else { return }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard frontPID == ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor [weak self] in
                self?.recoverMainWindowIfNeeded()
            }
        }

        appUpdateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recoverMissingMainSurfaceIfNeeded()
            }
        }
    }

    func recoverMainWindowIfNeeded() {
        if mainWindowController?.isVisible != true {
            showMainWindow()
        }
    }

    private func recoverMissingMainSurfaceIfNeeded() {
        guard !NSApp.isHidden else { return }
        guard mainWindowController?.needsMissingSurfaceRecovery != false else { return }
        showMainWindow()
    }

    func showMainWindow() {
        let environment = environment ?? AppEnvironment()
        self.environment = environment

        let controller = mainWindowController ?? NousMainWindowController(environment: environment)
        mainWindowController = controller
        controller.show()
    }
}

enum WindowRestorationPolicy {
    static let applePersistenceIgnoreStateKey = "ApplePersistenceIgnoreState"

    static func disablePersistentWindowRestoration(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: applePersistenceIgnoreStateKey)

        for key in defaults.dictionaryRepresentation().keys where isSwiftUIRestorationKey(key) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func isSwiftUIRestorationKey(_ key: String) -> Bool {
        key.hasPrefix("NSWindow Frame SwiftUI.")
            || key.hasPrefix("NSSplitView Subview Frames SwiftUI.")
    }
}
