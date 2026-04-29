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
        #if DEBUG
        .commands {
            CommandMenu("Debug") {
                Menu("Spike A: Panel Level") {
                    ForEach(PanelLevelSpikeCase.allCases) { spike in
                        Button("Show at \(spike.label)") {
                            PanelLevelSpike.shared.show(level: spike.level, label: spike.label)
                        }
                    }
                    Divider()
                    Button("Hide spike panel") {
                        PanelLevelSpike.shared.hide()
                    }
                }
            }
        }
        #endif
    }
}
