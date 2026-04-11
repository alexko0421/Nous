import SwiftUI

@main
struct NousApp: App {
    @State private var settingsVM: SettingsViewModel
    private let nodeStore: NodeStore
    private let embeddingService: EmbeddingService
    private let localLLM: LocalLLMService
    
    init() {
        // Core shared services
        let dbPath = Self.databasePath()
        let ns = try! NodeStore(path: dbPath)
        let es = EmbeddingService()
        let llm = LocalLLMService()
        
        self.nodeStore = ns
        self.embeddingService = es
        self.localLLM = llm
        
        // Settings VM as global state
        let svm = SettingsViewModel(
            embeddingService: es,
            localLLM: llm,
            nodeStore: ns
        )
        _settingsVM = State(initialValue: svm)
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(settingsVM: settingsVM, nodeStore: nodeStore, embeddingService: embeddingService, localLLM: localLLM)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 800, height: 600)
        
        Window("Settings", id: "settings-view") {
            SettingsView(vm: settingsVM)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
    
    private static func databasePath() -> String {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("Nous")
        if !FileManager.default.fileExists(atPath: appSupport.path) {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        return appSupport.appendingPathComponent("nous_v1.db").path
    }
}
