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
    let relationRefinementQueue: GalaxyRelationRefinementQueue
    let finderProjectSync: FinderProjectSyncService
    let conversationTitleBackfill: ConversationTitleBackfillService
    let memoryGraphMessageBackfill: MemoryGraphMessageBackfillService
    let memoryAtomEmbeddingBackfill: MemoryAtomEmbeddingBackfillService
    let userMemoryService: UserMemoryService
    let governanceTelemetry: GovernanceTelemetryStore
    let galaxyRelationTelemetry: GalaxyRelationTelemetry
    let scratchPadStore: ScratchPadStore
    let settingsVM: SettingsViewModel
    let chatVM: ChatViewModel
    let noteVM: NoteViewModel
    let galaxyVM: GalaxyViewModel
    let weeklyReflectionRollover: (@Sendable () async -> Void)?
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

    @MainActor
    static func bootstrap() -> AppBootstrapState {
        do {
            return .ready(try makeDependencies())
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    @MainActor
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

        do {
            _ = try MemoryGraphBackfillService(nodeStore: nodeStore).runIfNeeded()
        } catch {
            throw AppBootstrapError.migrationFailed(name: "MemoryGraphBackfillService", underlying: error)
        }

        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let localLLM = LocalLLMService()
        let settingsVM = SettingsViewModel(
            embeddingService: embeddingService,
            localLLM: localLLM,
            nodeStore: nodeStore
        )
        let galaxyRelationTelemetry = GalaxyRelationTelemetry()
        let graphEngine = GraphEngine(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            relationJudge: GalaxyRelationJudge(
                telemetry: galaxyRelationTelemetry,
                llmServiceProvider: {
                    guard settingsVM.backgroundAnalysisEnabled else { return nil }
                    return settingsVM.makeJudgeLLMService()
                }
            ),
            telemetry: galaxyRelationTelemetry
        )
        let relationRefinementQueue = GalaxyRelationRefinementQueue(
            refiner: graphEngine,
            isEnabled: {
                guard settingsVM.backgroundAnalysisEnabled else { return false }
                return settingsVM.makeJudgeLLMService() != nil
            },
            telemetry: galaxyRelationTelemetry
        )
        let finderProjectSync = FinderProjectSyncService(
            nodeStore: nodeStore,
            shouldExportAssistantThinking: { settingsVM.assistantThinkingEnabled }
        )
        let conversationTitleBackfill = ConversationTitleBackfillService(
            nodeStore: nodeStore,
            llmServiceProvider: { settingsVM.makeLLMService() }
        )
        let memoryGraphMessageBackfill = MemoryGraphMessageBackfillService(
            nodeStore: nodeStore,
            llmServiceProvider: { settingsVM.makeLLMService() }
        )
        let memoryAtomEmbeddingBackfill = MemoryAtomEmbeddingBackfillService(
            nodeStore: nodeStore,
            embed: { [embeddingService] text in
                guard embeddingService.isLoaded else { return nil }
                return try? embeddingService.embed(text)
            }
        )
        let governanceTelemetry = GovernanceTelemetryStore(nodeStore: nodeStore)
        let scratchPadStore = ScratchPadStore(nodeStore: nodeStore)
        let userMemoryService = UserMemoryService(
            nodeStore: nodeStore,
            llmServiceProvider: { settingsVM.makeLLMService() },
            governanceTelemetry: governanceTelemetry,
            embedFunction: { [embeddingService] text in
                guard embeddingService.isLoaded else { return nil }
                return try? embeddingService.embed(text)
            }
        )
        let scheduler = UserMemoryScheduler(service: userMemoryService.synthesizer)
        let conversationSessionStore = ConversationSessionStore(nodeStore: nodeStore)
        let chatVM = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            relationRefinementQueue: relationRefinementQueue,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            conversationSessionStore: conversationSessionStore,
            llmServiceProvider: { settingsVM.makeLLMService() },
            currentProviderProvider: { settingsVM.selectedProvider },
            judgeLLMServiceFactory: { settingsVM.makeJudgeLLMService() },
            governanceTelemetry: governanceTelemetry,
            scratchPadStore: scratchPadStore,
            shouldUseGeminiHistoryCache: { settingsVM.geminiHistoryCacheEnabled },
            shouldPersistAssistantThinking: { settingsVM.assistantThinkingEnabled }
        )
        let noteVM = NoteViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            relationRefinementQueue: relationRefinementQueue
        )
        let galaxyVM = GalaxyViewModel(nodeStore: nodeStore, graphEngine: graphEngine)

        // WeeklyReflectionService rollover closure. Called once per app launch
        // from ContentView.onAppear; idempotent via existsReflectionRun so
        // repeated launches in the same week are no-ops. Always runs on Gemini
        // 2.5 Pro regardless of the foreground provider — only requirement is
        // a configured Gemini API key (Settings surfaces the warning UI when
        // missing).
        let reflectionRollover: @Sendable () async -> Void = {
            guard settingsVM.backgroundAnalysisEnabled else { return }
            let key = settingsVM.geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            guard let (weekStart, weekEnd) = WeeklyReflectionService.previousCompletedWeek(now: Date())
            else { return }
            let llm = GeminiLLMService(apiKey: key)
            let service = WeeklyReflectionService(nodeStore: nodeStore, llm: llm)
            do {
                _ = try await service.runForWeek(
                    projectId: nil,
                    weekStart: weekStart,
                    weekEnd: weekEnd
                )
            } catch {
                // Swallow — failure was already persisted as a `.failed` row
                // inside the service. Next launch's rollover is a no-op on
                // that week.
            }
        }

        return AppDependencies(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            localLLM: localLLM,
            graphEngine: graphEngine,
            relationRefinementQueue: relationRefinementQueue,
            finderProjectSync: finderProjectSync,
            conversationTitleBackfill: conversationTitleBackfill,
            memoryGraphMessageBackfill: memoryGraphMessageBackfill,
            memoryAtomEmbeddingBackfill: memoryAtomEmbeddingBackfill,
            userMemoryService: userMemoryService,
            governanceTelemetry: governanceTelemetry,
            galaxyRelationTelemetry: galaxyRelationTelemetry,
            scratchPadStore: scratchPadStore,
            settingsVM: settingsVM,
            chatVM: chatVM,
            noteVM: noteVM,
            galaxyVM: galaxyVM,
            weeklyReflectionRollover: reflectionRollover
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
