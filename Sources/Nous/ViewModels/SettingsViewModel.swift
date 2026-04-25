import Foundation
import Observation

@Observable
final class SettingsViewModel {
    struct RuntimeModelSummary: Identifiable, Equatable {
        let label: String
        let model: String
        let detail: String

        var id: String { label }
    }

    private enum ModelCatalog {
        static let geminiForeground = "gemini-2.5-pro"
        static let geminiJudge = "gemini-2.5-flash-lite"
        static let geminiReflection = "gemini-2.5-pro"
        static let claudeForeground = "claude-sonnet-4-6-20250414"
        static let claudeJudge = "claude-haiku-4-5-20251001"
        static let openAIForeground = "gpt-4o"
        static let openAIJudge = "gpt-4o-mini"
        static let openRouterForeground = "anthropic/claude-sonnet-4.6"
    }

    // MARK: - Provider selection

    var selectedProvider: LLMProvider = .gemini

    // MARK: - API keys

    var geminiApiKey: String = ""
    var claudeApiKey: String = ""
    var openaiApiKey: String = ""
    var openrouterApiKey: String = ""
    var finderSyncEnabled: Bool = false
    var backgroundAnalysisEnabled: Bool = false
    var geminiHistoryCacheEnabled: Bool = false
    var assistantThinkingEnabled: Bool = false

    // MARK: - Model identifiers

    var localModelId: String = LocalLLMService.defaultModelId
    var embeddingModelId: String = EmbeddingService.defaultModelId

    // MARK: - Model state

    var isLLMLoaded: Bool = false
    var isEmbeddingLoaded: Bool = false
    var llmDownloadProgress: Double = 0
    var embeddingDownloadProgress: Double = 0

    // MARK: - Vector DB stats

    var vectorCount: Int = 0
    var databaseSize: String = "—"

    // MARK: - Dependencies

    private let embeddingService: EmbeddingService
    private let localLLM: LocalLLMService
    let nodeStore: NodeStore
    private let defaults: UserDefaults
    private let secretStore: any SecretStore

    var credentialStorageDescription: String {
        secretStore.storageDescription
    }

    var runtimeModelSummaries: [RuntimeModelSummary] {
        [
            RuntimeModelSummary(
                label: "Foreground chat",
                model: foregroundModelName,
                detail: foregroundModelDetail
            ),
            RuntimeModelSummary(
                label: "Judge tasks",
                model: judgeModelName,
                detail: judgeModelDetail
            ),
            RuntimeModelSummary(
                label: "Weekly reflections",
                model: ModelCatalog.geminiReflection,
                detail: weeklyReflectionDetail
            )
        ]
    }

    // MARK: - UserDefaults keys

    private enum Keys {
        static let provider     = "nous.llm.provider"
        static let geminiApiKey = "nous.gemini.apikey"
        static let claudeApiKey = "nous.claude.apikey"
        static let openaiApiKey = "nous.openai.apikey"
        static let openrouterApiKey = "nous.openrouter.apikey"
        static let localModelId = "nous.local.modelid"
        static let embedModelId = "nous.embedding.modelid"
        static let finderSyncEnabled = "nous.finder.sync.enabled"
        static let backgroundAnalysisEnabled = "nous.background.analysis.enabled"
        static let geminiHistoryCacheEnabled = "nous.gemini.history.cache.enabled"
        static let assistantThinkingEnabled = "nous.assistant.thinking.enabled"
    }

    // MARK: - Init

    init(
        embeddingService: EmbeddingService,
        localLLM: LocalLLMService,
        nodeStore: NodeStore,
        defaults: UserDefaults = .standard,
        secretStore: any SecretStore = SettingsViewModel.defaultSecretStore()
    ) {
        self.embeddingService = embeddingService
        self.localLLM = localLLM
        self.nodeStore = nodeStore
        self.defaults = defaults
        self.secretStore = secretStore
        loadPreferences()
        syncModelState()
    }

    // MARK: - Preferences

    func loadPreferences() {
        if let raw = defaults.string(forKey: Keys.provider),
           let provider = LLMProvider(rawValue: raw) {
            selectedProvider = provider
        }
        geminiApiKey = loadSecret(account: Keys.geminiApiKey)
        claudeApiKey = loadSecret(account: Keys.claudeApiKey)
        openaiApiKey = loadSecret(account: Keys.openaiApiKey)
        openrouterApiKey = loadSecret(account: Keys.openrouterApiKey)
        finderSyncEnabled = defaults.bool(forKey: Keys.finderSyncEnabled)
        backgroundAnalysisEnabled = defaults.bool(forKey: Keys.backgroundAnalysisEnabled)
        geminiHistoryCacheEnabled = defaults.bool(forKey: Keys.geminiHistoryCacheEnabled)
        assistantThinkingEnabled = defaults.bool(forKey: Keys.assistantThinkingEnabled)
        if let id = defaults.string(forKey: Keys.localModelId) {
            localModelId = id
        }
        if let id = defaults.string(forKey: Keys.embedModelId) {
            embeddingModelId = id
        }
        enforcePrivacyPreferences()
    }

    func savePreferences() {
        defaults.set(selectedProvider.rawValue, forKey: Keys.provider)
        defaults.set(finderSyncEnabled, forKey: Keys.finderSyncEnabled)
        defaults.set(backgroundAnalysisEnabled, forKey: Keys.backgroundAnalysisEnabled)
        defaults.set(geminiHistoryCacheEnabled, forKey: Keys.geminiHistoryCacheEnabled)
        defaults.set(assistantThinkingEnabled, forKey: Keys.assistantThinkingEnabled)
        defaults.set(localModelId, forKey: Keys.localModelId)
        defaults.set(embeddingModelId, forKey: Keys.embedModelId)
        persistSecret(geminiApiKey, account: Keys.geminiApiKey)
        persistSecret(claudeApiKey, account: Keys.claudeApiKey)
        persistSecret(openaiApiKey, account: Keys.openaiApiKey)
        persistSecret(openrouterApiKey, account: Keys.openrouterApiKey)
        enforcePrivacyPreferences()
    }

    // MARK: - Model loading

    func loadEmbeddingModel() async {
        do {
            try await embeddingService.loadModel(id: embeddingModelId)
        } catch {
            // surface error via state — embedding stays unloaded
        }
        syncModelState()
    }

    func loadLocalLLM() async {
        do {
            try await localLLM.loadModel(id: localModelId)
        } catch {
            // surface error via state — model stays unloaded
        }
        syncModelState()
    }

    // MARK: - Stats

    func updateStats() {
        vectorCount = (try? nodeStore.fetchNodesWithEmbeddings().count) ?? 0
        let totalNodes = (try? nodeStore.fetchAllNodes().count) ?? 0
        databaseSize = "\(totalNodes) nodes"
    }

    // MARK: - LLM factory

    func makeLLMService() -> (any LLMService)? {
        switch selectedProvider {
        case .local:
            guard localLLM.isLoaded else { return nil }
            return localLLM
        case .gemini:
            guard !geminiApiKey.isEmpty else { return nil }
            return GeminiLLMService(apiKey: geminiApiKey, model: ModelCatalog.geminiForeground)
        case .claude:
            guard !claudeApiKey.isEmpty else { return nil }
            return ClaudeLLMService(apiKey: claudeApiKey, model: ModelCatalog.claudeForeground)
        case .openai:
            guard !openaiApiKey.isEmpty else { return nil }
            return OpenAILLMService(apiKey: openaiApiKey, model: ModelCatalog.openAIForeground)
        case .openrouter:
            guard !openrouterApiKey.isEmpty else { return nil }
            return OpenRouterLLMService(apiKey: openrouterApiKey, model: ModelCatalog.openRouterForeground)
        }
    }

    func makeJudgeLLMService() -> (any LLMService)? {
        switch selectedProvider {
        case .local:
            return nil
        case .gemini:
            guard !geminiApiKey.isEmpty else { return nil }
            return GeminiLLMService(apiKey: geminiApiKey, model: ModelCatalog.geminiJudge)
        case .claude:
            guard !claudeApiKey.isEmpty else { return nil }
            return ClaudeLLMService(apiKey: claudeApiKey, model: ModelCatalog.claudeJudge)
        case .openai:
            guard !openaiApiKey.isEmpty else { return nil }
            return OpenAILLMService(apiKey: openaiApiKey, model: ModelCatalog.openAIJudge)
        case .openrouter:
            return nil
        }
    }

    // MARK: - Private helpers

    private var foregroundModelName: String {
        switch selectedProvider {
        case .local:
            return localModelId
        case .gemini:
            return ModelCatalog.geminiForeground
        case .claude:
            return ModelCatalog.claudeForeground
        case .openai:
            return ModelCatalog.openAIForeground
        case .openrouter:
            return ModelCatalog.openRouterForeground
        }
    }

    private var foregroundModelDetail: String {
        switch selectedProvider {
        case .local:
            return localLLM.isLoaded
                ? "Runs fully on-device with the currently loaded MLX model."
                : "Selected for foreground chat, but the local model still needs to be loaded."
        case .gemini:
            return "Uses the selected Gemini provider for normal conversation turns."
        case .claude:
            return "Uses Anthropic directly for normal conversation turns."
        case .openai:
            return "Uses OpenAI directly for normal conversation turns."
        case .openrouter:
            return "Uses OpenRouter for normal conversation turns."
        }
    }

    private var judgeModelName: String {
        switch selectedProvider {
        case .local:
            return "Disabled"
        case .gemini:
            return ModelCatalog.geminiJudge
        case .claude:
            return ModelCatalog.claudeJudge
        case .openai:
            return ModelCatalog.openAIJudge
        case .openrouter:
            return "Disabled"
        }
    }

    private var judgeModelDetail: String {
        switch selectedProvider {
        case .local:
            return "Judge tasks are skipped on Local because the structured-output path is disabled there."
        case .gemini:
            return "Separate lightweight judge model for retrieval and provocation decisions."
        case .claude:
            return "Separate lightweight judge model for retrieval and provocation decisions."
        case .openai:
            return "Separate lightweight judge model for retrieval and provocation decisions."
        case .openrouter:
            return "Judge tasks are temporarily disabled on OpenRouter so slow judge calls cannot block the main reply."
        }
    }

    private var weeklyReflectionDetail: String {
        if !backgroundAnalysisEnabled {
            return "Only runs when Background AI maintenance is turned on."
        }
        if geminiApiKey.isEmpty {
            return "Background AI maintenance is on, but a Gemini API key is still required."
        }
        return "Always runs on Gemini, regardless of the foreground provider."
    }

    private func syncModelState() {
        isLLMLoaded = localLLM.isLoaded
        llmDownloadProgress = localLLM.downloadProgress
        isEmbeddingLoaded = embeddingService.isLoaded
        embeddingDownloadProgress = embeddingService.downloadProgress
    }

    private static func defaultSecretStore() -> any SecretStore {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return VolatileSecretStore()
        }
        #if DEBUG
        return UserDefaultsSecretStore()
        #else
        return KeychainSecretStore()
        #endif
    }

    private func loadSecret(account: String) -> String {
        if let stored = secretStore.string(for: account) {
            defaults.removeObject(forKey: account)
            return stored
        }

        guard let legacy = defaults.string(forKey: account) else {
            return ""
        }

        persistSecret(legacy, account: account)
        return normalizedSecret(legacy) ?? ""
    }

    private func persistSecret(_ value: String, account: String) {
        secretStore.setString(normalizedSecret(value), for: account)
        defaults.removeObject(forKey: account)
    }

    private func normalizedSecret(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func enforcePrivacyPreferences() {
        guard !assistantThinkingEnabled else { return }
        try? nodeStore.clearAllMessageThinkingContent()
    }
}
