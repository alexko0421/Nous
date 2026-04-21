import SwiftUI

@main
struct NousApp: App {
    @State private var env = AppEnvironment()

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
