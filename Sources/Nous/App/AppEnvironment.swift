import SwiftUI
import AppKit

enum AppBootstrapState {
    case initializing
    case ready(AppDependencies)
    case failed(String)
}

struct AppDependencies {
    let nodeStore: NodeStore
    let vectorStore: VectorStore
    let embeddingService: EmbeddingService
    let localLLM: LocalLLMService
    let graphEngine: GraphEngine
    let finderProjectSync: FinderProjectSyncService
    let userMemoryService: UserMemoryService
    let governanceTelemetry: GovernanceTelemetryStore
    let scratchPadStore: ScratchPadStore
    let settingsVM: SettingsViewModel
    let chatVM: ChatViewModel
    let noteVM: NoteViewModel
    let galaxyVM: GalaxyViewModel
}

enum AppBootstrapError: LocalizedError {
    case applicationSupportDirectoryUnavailable
    case createDirectoryFailed(path: String, underlying: Error)
    case openDatabaseFailed(path: String, underlying: Error)
    case migrationFailed(name: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            return "Could not locate Application Support."
        case .createDirectoryFailed(let path, let underlying):
            return "Could not create Nous data directory at \(path): \(underlying.localizedDescription)"
        case .openDatabaseFailed(let path, let underlying):
            return "Could not open Nous database at \(path): \(underlying.localizedDescription)"
        case .migrationFailed(let name, let underlying):
            return "\(name) failed during launch: \(underlying.localizedDescription)"
        }
    }
}

@Observable
final class AppEnvironment {
    var state: AppBootstrapState = .initializing
    private static let bootstrapLock = NSLock()

    @MainActor
    init() {
        self.state = Self.bootstrap()
    }

    static func bootstrap() -> AppBootstrapState {
        do {
            return .ready(try makeDependencies())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func makeDependencies() throws -> AppDependencies {
        bootstrapLock.lock()
        defer { bootstrapLock.unlock() }

        let dbPath = try databasePath()
        let nodeStore: NodeStore
        do {
            nodeStore = try NodeStore(path: dbPath)
        } catch {
            throw AppBootstrapError.openDatabaseFailed(path: dbPath, underlying: error)
        }

        do {
            try MemoryV2Migrator.runIfNeeded(db: nodeStore.rawDatabase)
        } catch {
            throw AppBootstrapError.migrationFailed(name: "MemoryV2Migrator", underlying: error)
        }

        do {
            try MemoryEntriesMigrator.runIfNeeded(store: nodeStore)
        } catch {
            throw AppBootstrapError.migrationFailed(name: "MemoryEntriesMigrator", underlying: error)
        }

        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let localLLM = LocalLLMService()
        let graphEngine = GraphEngine(nodeStore: nodeStore, vectorStore: vectorStore)
        let finderProjectSync = FinderProjectSyncService(nodeStore: nodeStore)
        let settingsVM = SettingsViewModel(
            embeddingService: embeddingService,
            localLLM: localLLM,
            nodeStore: nodeStore
        )
        let governanceTelemetry = GovernanceTelemetryStore(nodeStore: nodeStore)
        let scratchPadStore = MainActor.assumeIsolated { ScratchPadStore() }
        let userMemoryService = UserMemoryService(
            nodeStore: nodeStore,
            llmServiceProvider: { settingsVM.makeLLMService() },
            governanceTelemetry: governanceTelemetry
        )
        let scheduler = UserMemoryScheduler(service: userMemoryService)
        let chatVM = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            llmServiceProvider: { settingsVM.makeLLMService() },
            currentProviderProvider: { settingsVM.selectedProvider },
            judgeLLMServiceFactory: { settingsVM.makeJudgeLLMService() },
            governanceTelemetry: governanceTelemetry,
            scratchPadStore: scratchPadStore
        )
        let noteVM = NoteViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine
        )
        let galaxyVM = GalaxyViewModel(nodeStore: nodeStore, graphEngine: graphEngine)

        return AppDependencies(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            localLLM: localLLM,
            graphEngine: graphEngine,
            finderProjectSync: finderProjectSync,
            userMemoryService: userMemoryService,
            governanceTelemetry: governanceTelemetry,
            scratchPadStore: scratchPadStore,
            settingsVM: settingsVM,
            chatVM: chatVM,
            noteVM: noteVM,
            galaxyVM: galaxyVM
        )
    }

    private static func databasePath() throws -> String {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else {
            throw AppBootstrapError.applicationSupportDirectoryUnavailable
        }

        let nousDir = appSupport.appendingPathComponent("Nous", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: nousDir, withIntermediateDirectories: true)
        } catch {
            throw AppBootstrapError.createDirectoryFailed(path: nousDir.path, underlying: error)
        }
        return nousDir.appendingPathComponent("nous.db").path
    }
}
