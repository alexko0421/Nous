import SwiftUI
import AppKit

@main
struct NousApp: App {
    @State private var env = AppEnvironment()
    @NSApplicationDelegateAdaptor(NousAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(env: env)
                .ignoresSafeArea(.all)
                .toolbarBackground(.hidden, for: .windowToolbar)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 850, height: 650)
    }
}

/// Keeps the app running after the main window is closed so that voice mode
/// and the notch capsule continue to function. Closing the main window now
/// hides Nous; clicking the dock icon brings it back.
final class NousAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
