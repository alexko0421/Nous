import Foundation
import Observation

@Observable
final class SettingsViewModel {

    // MARK: - Provider selection

    var selectedProvider: LLMProvider = .local

    // MARK: - API keys

    var geminiApiKey: String = ""
    var claudeApiKey: String = ""
    var openaiApiKey: String = ""

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
    private let nodeStore: NodeStore

    // MARK: - UserDefaults keys

    private enum Keys {
        static let provider     = "nous.llm.provider"
        static let geminiApiKey = "nous.gemini.apikey"
        static let claudeApiKey = "nous.claude.apikey"
        static let openaiApiKey = "nous.openai.apikey"
        static let localModelId = "nous.local.modelid"
        static let embedModelId = "nous.embedding.modelid"
    }

    // MARK: - Init

    init(embeddingService: EmbeddingService, localLLM: LocalLLMService, nodeStore: NodeStore) {
        self.embeddingService = embeddingService
        self.localLLM = localLLM
        self.nodeStore = nodeStore
        loadPreferences()
        syncModelState()
    }

    // MARK: - Preferences

    func loadPreferences() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Keys.provider),
           let provider = LLMProvider(rawValue: raw) {
            selectedProvider = provider
        }
        geminiApiKey = defaults.string(forKey: Keys.geminiApiKey) ?? ""
        claudeApiKey = defaults.string(forKey: Keys.claudeApiKey) ?? ""
        openaiApiKey = defaults.string(forKey: Keys.openaiApiKey) ?? ""
        if let id = defaults.string(forKey: Keys.localModelId) {
            localModelId = id
        }
        if let id = defaults.string(forKey: Keys.embedModelId) {
            embeddingModelId = id
        }
    }

    func savePreferences() {
        let defaults = UserDefaults.standard
        defaults.set(selectedProvider.rawValue, forKey: Keys.provider)
        defaults.set(geminiApiKey, forKey: Keys.geminiApiKey)
        defaults.set(claudeApiKey, forKey: Keys.claudeApiKey)
        defaults.set(openaiApiKey, forKey: Keys.openaiApiKey)
        defaults.set(localModelId, forKey: Keys.localModelId)
        defaults.set(embeddingModelId, forKey: Keys.embedModelId)
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
            return GeminiLLMService(apiKey: geminiApiKey)
        case .claude:
            guard !claudeApiKey.isEmpty else { return nil }
            return ClaudeLLMService(apiKey: claudeApiKey)
        case .openai:
            guard !openaiApiKey.isEmpty else { return nil }
            return OpenAILLMService(apiKey: openaiApiKey)
        }
    }

    // MARK: - Private helpers

    private func syncModelState() {
        isLLMLoaded = localLLM.isLoaded
        llmDownloadProgress = localLLM.downloadProgress
        isEmbeddingLoaded = embeddingService.isLoaded
        embeddingDownloadProgress = embeddingService.downloadProgress
    }
}
