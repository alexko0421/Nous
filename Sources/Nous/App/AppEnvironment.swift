import SwiftUI
import AppKit

enum AppBootstrapState {
    case initializing
    case ready(AppDependencies)
    case failed(String)
}

struct AppDependencies {
    let nodeStore: NodeStore
    let skillStore: SkillStore
    let skillMatcher: SkillMatcher
    let skillTracker: SkillTracker
    let seedSkillImporter: SeedSkillImporter
    let shadowLearningStore: ShadowLearningStore
    let shadowLearningSignalRecorder: ShadowLearningSignalRecorder
    let shadowPatternPromptProvider: ShadowPatternPromptProvider
    let shadowLearningSteward: ShadowLearningSteward
    let heartbeatCoordinator: HeartbeatCoordinator
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
    let backgroundAITelemetry: BackgroundAIJobTelemetryStore
    let galaxyRelationTelemetry: GalaxyRelationTelemetry
    let scratchPadStore: ScratchPadStore
    let voiceController: VoiceCommandController
    let voiceTranscriptCommitter: VoiceTranscriptCommitter
    let settingsVM: SettingsViewModel
    let chatVM: ChatViewModel
    let noteVM: NoteViewModel
    let galaxyVM: GalaxyViewModel
    let beadsAgentWorkVM: BeadsAgentWorkViewModel
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
    static let databasePathOverrideKey = "NOUS_DATABASE_PATH"
    static let databaseProfileKey = "NOUS_DATABASE_PROFILE"

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

        let skillStore = SkillStore(nodeStore: nodeStore)
        let skillMatcher = SkillMatcher()
        let skillTracker = SkillTracker(store: skillStore)
        let seedSkillImporter = SeedSkillImporter(store: skillStore)
        let shadowLearningStore = ShadowLearningStore(nodeStore: nodeStore)
        let shadowLearningSignalRecorder = ShadowLearningSignalRecorder(store: shadowLearningStore)
        let shadowPatternPromptProvider = ShadowPatternPromptProvider(store: shadowLearningStore)
        let shadowLearningSteward = ShadowLearningSteward(store: shadowLearningStore)
        do {
            try seedSkillImporter.importSeeds()
        } catch {
            print("[SeedSkillImporter] failed during launch: \(error)")
        }

        let vectorStore = VectorStore(nodeStore: nodeStore)
        let embeddingService = EmbeddingService()
        let localLLM = LocalLLMService()
        let settingsVM = SettingsViewModel(
            embeddingService: embeddingService,
            localLLM: localLLM,
            nodeStore: nodeStore
        )
        let slowCognitionArtifactProvider = SlowCognitionArtifactProvider(
            nodeStore: nodeStore,
            shadowLearningStore: shadowLearningStore,
            isEnabled: { settingsVM.backgroundAnalysisEnabled }
        )
        let heartbeatCoordinator = HeartbeatCoordinator(
            shadowLearningSteward: shadowLearningSteward,
            isEnabled: { settingsVM.backgroundAnalysisEnabled }
        )
        let galaxyRelationTelemetry = GalaxyRelationTelemetry()
        let backgroundAITelemetry = BackgroundAIJobTelemetryStore()
        let graphEngine = GraphEngine(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            relationJudge: GalaxyRelationJudge(
                telemetry: galaxyRelationTelemetry,
                backgroundTelemetry: backgroundAITelemetry,
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
            llmServiceProvider: { settingsVM.makeLLMService(openRouterWebSearchEnabled: false) },
            backgroundTelemetry: backgroundAITelemetry
        )
        let memoryGraphMessageBackfill = MemoryGraphMessageBackfillService(
            nodeStore: nodeStore,
            llmServiceProvider: { settingsVM.makeLLMService(openRouterWebSearchEnabled: false) },
            backgroundTelemetry: backgroundAITelemetry
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
            llmServiceProvider: { settingsVM.makeLLMService(openRouterWebSearchEnabled: false) },
            governanceTelemetry: governanceTelemetry,
            embedFunction: { [embeddingService] text in
                guard embeddingService.isLoaded else { return nil }
                return try? embeddingService.embed(text)
            }
        )
        let voiceMemoryFacade = VoiceMemoryFacade(nodeStore: nodeStore)
        let voiceController = VoiceCommandController(memory: voiceMemoryFacade)
        let scheduler = UserMemoryScheduler(service: userMemoryService.synthesizer)
        let conversationSessionStore = ConversationSessionStore(
            nodeStore: nodeStore,
            telemetry: governanceTelemetry
        )
        let chatVM = ChatViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            relationRefinementQueue: relationRefinementQueue,
            userMemoryService: userMemoryService,
            userMemoryScheduler: scheduler,
            conversationSessionStore: conversationSessionStore,
            llmServiceProvider: { settingsVM.makeLLMService(openRouterWebSearchEnabled: settingsVM.openRouterWebSearchEnabled) },
            currentProviderProvider: { settingsVM.selectedProvider },
            judgeLLMServiceFactory: { settingsVM.makeJudgeLLMService() },
            skillStore: skillStore,
            skillMatcher: skillMatcher,
            skillTracker: skillTracker,
            governanceTelemetry: governanceTelemetry,
            scratchPadStore: scratchPadStore,
            shadowLearningSignalRecorder: shadowLearningSignalRecorder,
            shadowPatternPromptProvider: shadowPatternPromptProvider,
            slowCognitionArtifactProvider: slowCognitionArtifactProvider,
            heartbeatCoordinator: heartbeatCoordinator,
            shouldUseGeminiHistoryCache: { settingsVM.geminiHistoryCacheEnabled },
            shouldPersistAssistantThinking: { settingsVM.assistantThinkingEnabled }
        )
        let voiceTranscriptCommitter = VoiceTranscriptCommitter(
            voiceController: voiceController,
            chatViewModel: chatVM
        )
        let noteVM = NoteViewModel(
            nodeStore: nodeStore,
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            graphEngine: graphEngine,
            relationRefinementQueue: relationRefinementQueue
        )
        let galaxyVM = GalaxyViewModel(nodeStore: nodeStore, graphEngine: graphEngine)
        let beadsAgentWorkVM = BeadsAgentWorkViewModel(
            service: BeadsAgentWorkService(
                runtimeHarnessLoader: RuntimeHarnessService(
                    telemetry: governanceTelemetry,
                    nodeStore: nodeStore
                )
            )
        )

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
            let service = WeeklyReflectionService(
                nodeStore: nodeStore,
                llm: llm,
                backgroundTelemetry: backgroundAITelemetry
            )
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
            skillStore: skillStore,
            skillMatcher: skillMatcher,
            skillTracker: skillTracker,
            seedSkillImporter: seedSkillImporter,
            shadowLearningStore: shadowLearningStore,
            shadowLearningSignalRecorder: shadowLearningSignalRecorder,
            shadowPatternPromptProvider: shadowPatternPromptProvider,
            shadowLearningSteward: shadowLearningSteward,
            heartbeatCoordinator: heartbeatCoordinator,
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
            backgroundAITelemetry: backgroundAITelemetry,
            galaxyRelationTelemetry: galaxyRelationTelemetry,
            scratchPadStore: scratchPadStore,
            voiceController: voiceController,
            voiceTranscriptCommitter: voiceTranscriptCommitter,
            settingsVM: settingsVM,
            chatVM: chatVM,
            noteVM: noteVM,
            galaxyVM: galaxyVM,
            beadsAgentWorkVM: beadsAgentWorkVM,
            weeklyReflectionRollover: reflectionRollover
        )
    }

    static func databasePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil
    ) throws -> String {
        if let overridePath = normalizedEnvironmentValue(environment[databasePathOverrideKey]) {
            return try prepareDatabaseFile(
                at: URL(fileURLWithPath: overridePath).standardizedFileURL,
                fileManager: fileManager
            )
        }

        guard let appSupport = applicationSupportURL ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first else {
            throw AppBootstrapError.applicationSupportDirectoryUnavailable
        }

        let nousDir = appSupport
            .appendingPathComponent("Nous", isDirectory: true)
            .appendingDatabaseProfileDirectory(environment[databaseProfileKey])

        return try prepareDatabaseFile(
            at: nousDir.appendingPathComponent("nous.db", isDirectory: false),
            fileManager: fileManager
        )
    }

    private static func prepareDatabaseFile(
        at databaseURL: URL,
        fileManager: FileManager
    ) throws -> String {
        let directoryURL = databaseURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw AppBootstrapError.createDirectoryFailed(path: directoryURL.path, underlying: error)
        }
        return databaseURL.path
    }

    private static func normalizedEnvironmentValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension URL {
    func appendingDatabaseProfileDirectory(_ rawProfile: String?) -> URL {
        guard let profile = AppEnvironment.sanitizedDatabaseProfile(rawProfile) else {
            return self
        }
        return appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true)
    }
}

extension AppEnvironment {
    static func sanitizedDatabaseProfile(_ rawProfile: String?) -> String? {
        guard let rawProfile = normalizedEnvironmentValue(rawProfile) else { return nil }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = rawProfile.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))

        return collapsed.isEmpty ? nil : collapsed
    }
}
