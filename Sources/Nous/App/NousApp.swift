import SwiftUI
import AppKit

@main
struct NousApp: App {
    @NSApplicationDelegateAdaptor(NousAppDelegate.self) private var appDelegate

    init() {
        WindowRestorationPolicy.disablePersistentWindowRestoration()
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
    private var environment: AppEnvironment?
    private var mainWindowController: NousMainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    private func showMainWindow() {
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
