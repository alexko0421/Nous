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
        static let geminiJudge = "gemini-2.5-pro"
        static let geminiReflection = "gemini-2.5-pro"
        static let claudeForeground = "claude-sonnet-4-6"
        static let claudeJudge = "claude-sonnet-4-6"
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
    var openRouterWebSearchEnabled: Bool = true
    var geminiHistoryCacheEnabled: Bool = false
    var assistantThinkingEnabled: Bool = false
    var voiceOutputVoice: VoiceOutputVoice = .cedar
    var voiceLanguage: VoiceLanguage = .automatic
    var isPreviewingVoice: Bool = false
    var voicePreviewError: String?

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
    private let voicePreviewer: any VoicePreviewing

    var credentialStorageDescription: String {
        secretStore.storageDescription
    }

    var isVoiceModeAvailable: Bool {
        !openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var shouldShowSupplementalGeminiKeyField: Bool {
        selectedProvider != .gemini
    }

    var voiceModeUnavailableReason: String? {
        isVoiceModeAvailable ? nil : "Add an OpenAI API key to use Voice Mode."
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
        static let openRouterWebSearchEnabled = "nous.openrouter.websearch.enabled"
        static let geminiHistoryCacheEnabled = "nous.gemini.history.cache.enabled"
        static let assistantThinkingEnabled = "nous.assistant.thinking.enabled"
        static let voiceOutputVoice = "nous.voice.outputVoice"
        static let voiceLanguage = "nous.voice.language"
    }

    // MARK: - Init

    init(
        embeddingService: EmbeddingService,
        localLLM: LocalLLMService,
        nodeStore: NodeStore,
        defaults: UserDefaults = .standard,
        secretStore: any SecretStore = SettingsViewModel.defaultSecretStore(),
        voicePreviewer: any VoicePreviewing = OpenAIVoicePreviewService()
    ) {
        self.embeddingService = embeddingService
        self.localLLM = localLLM
        self.nodeStore = nodeStore
        self.defaults = defaults
        self.secretStore = secretStore
        self.voicePreviewer = voicePreviewer
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
        openRouterWebSearchEnabled = defaults.object(forKey: Keys.openRouterWebSearchEnabled) as? Bool ?? true
        geminiHistoryCacheEnabled = defaults.bool(forKey: Keys.geminiHistoryCacheEnabled)
        assistantThinkingEnabled = defaults.bool(forKey: Keys.assistantThinkingEnabled)
        if let id = defaults.string(forKey: Keys.localModelId) {
            localModelId = id
        }
        if let id = defaults.string(forKey: Keys.embedModelId) {
            embeddingModelId = id
        }
        if let raw = defaults.string(forKey: Keys.voiceOutputVoice),
           let voice = VoiceOutputVoice(rawValue: raw) {
            voiceOutputVoice = voice
        }
        if let raw = defaults.string(forKey: Keys.voiceLanguage),
           let language = VoiceLanguage(rawValue: raw) {
            voiceLanguage = language
        }
        enforcePrivacyPreferences()
    }

    func savePreferences() {
        defaults.set(selectedProvider.rawValue, forKey: Keys.provider)
        defaults.set(finderSyncEnabled, forKey: Keys.finderSyncEnabled)
        defaults.set(backgroundAnalysisEnabled, forKey: Keys.backgroundAnalysisEnabled)
        defaults.set(openRouterWebSearchEnabled, forKey: Keys.openRouterWebSearchEnabled)
        defaults.set(geminiHistoryCacheEnabled, forKey: Keys.geminiHistoryCacheEnabled)
        defaults.set(assistantThinkingEnabled, forKey: Keys.assistantThinkingEnabled)
        defaults.set(localModelId, forKey: Keys.localModelId)
        defaults.set(embeddingModelId, forKey: Keys.embedModelId)
        defaults.set(voiceOutputVoice.rawValue, forKey: Keys.voiceOutputVoice)
        defaults.set(voiceLanguage.rawValue, forKey: Keys.voiceLanguage)
        persistSecret(geminiApiKey, account: Keys.geminiApiKey)
        persistSecret(claudeApiKey, account: Keys.claudeApiKey)
        persistSecret(openaiApiKey, account: Keys.openaiApiKey)
        persistSecret(openrouterApiKey, account: Keys.openrouterApiKey)
        enforcePrivacyPreferences()
    }

    @MainActor
    func previewSelectedVoice() async {
        let apiKey = openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            voicePreviewError = "Add OpenAI Realtime API key first."
            return
        }

        isPreviewingVoice = true
        voicePreviewError = nil
        defer { isPreviewingVoice = false }

        do {
            try await voicePreviewer.preview(
                apiKey: apiKey,
                voice: voiceOutputVoice,
                language: voiceLanguage
            )
        } catch {
            voicePreviewError = "Could not preview voice."
        }
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

    func makeLLMService(openRouterWebSearchEnabled webSearchOverride: Bool? = nil) -> (any LLMService)? {
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
            return OpenRouterLLMService(
                apiKey: openrouterApiKey,
                model: ModelCatalog.openRouterForeground,
                webSearchEnabled: webSearchOverride ?? openRouterWebSearchEnabled
            )
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
            guard !openrouterApiKey.isEmpty else { return nil }
            return OpenRouterLLMService(
                apiKey: openrouterApiKey,
                model: ModelCatalog.openRouterForeground,
                webSearchEnabled: false
            )
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
            return ModelCatalog.openRouterForeground
        }
    }

    private var judgeModelDetail: String {
        switch selectedProvider {
        case .local:
            return "Judge tasks are skipped on Local because the structured-output path is disabled there."
        case .gemini:
            if geminiApiKey.isEmpty {
                return "Missing Gemini API key; judge checks are currently skipped."
            }
            return "Separate lightweight judge model for retrieval and provocation decisions."
        case .claude:
            return "Separate lightweight judge model for retrieval and provocation decisions."
        case .openai:
            return "Separate lightweight judge model for retrieval and provocation decisions."
        case .openrouter:
            if openrouterApiKey.isEmpty {
                return "Missing OpenRouter API key; judge checks are currently skipped."
            }
            return "Uses OpenRouter Sonnet 4.6 for judge checks while OpenRouter handles foreground chat."
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
