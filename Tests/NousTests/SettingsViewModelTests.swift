import XCTest
@testable import Nous

final class SettingsViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var secretStore: InMemorySecretStore!
    private var nodeStore: NodeStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "settings-vm-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        secretStore = InMemorySecretStore()
        nodeStore = try NodeStore(path: ":memory:")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        secretStore = nil
        nodeStore = nil
        try super.tearDownWithError()
    }

    func testLoadPreferencesMigratesLegacyApiKeysOutOfUserDefaults() {
        defaults.set("legacy-gemini-key", forKey: "nous.gemini.apikey")
        defaults.set("legacy-claude-key", forKey: "nous.claude.apikey")
        defaults.set("legacy-openai-key", forKey: "nous.openai.apikey")

        let vm = makeViewModel()

        XCTAssertEqual(vm.geminiApiKey, "legacy-gemini-key")
        XCTAssertEqual(vm.claudeApiKey, "legacy-claude-key")
        XCTAssertEqual(vm.openaiApiKey, "legacy-openai-key")
        XCTAssertEqual(secretStore.values["nous.gemini.apikey"], "legacy-gemini-key")
        XCTAssertEqual(secretStore.values["nous.claude.apikey"], "legacy-claude-key")
        XCTAssertEqual(secretStore.values["nous.openai.apikey"], "legacy-openai-key")
        XCTAssertNil(defaults.string(forKey: "nous.gemini.apikey"))
        XCTAssertNil(defaults.string(forKey: "nous.claude.apikey"))
        XCTAssertNil(defaults.string(forKey: "nous.openai.apikey"))
    }

    func testSavePreferencesPersistsApiKeysOnlyToSecretStore() {
        let vm = makeViewModel()
        vm.selectedProvider = .openai
        vm.geminiApiKey = "  gemini-key  "
        vm.claudeApiKey = ""
        vm.openaiApiKey = "openai-key"
        vm.finderSyncEnabled = true
        vm.backgroundAnalysisEnabled = true
        vm.geminiHistoryCacheEnabled = true
        vm.assistantThinkingEnabled = true
        vm.localModelId = "local-model"
        vm.embeddingModelId = "embed-model"

        vm.savePreferences()

        XCTAssertEqual(defaults.string(forKey: "nous.llm.provider"), LLMProvider.openai.rawValue)
        XCTAssertTrue(defaults.bool(forKey: "nous.finder.sync.enabled"))
        XCTAssertTrue(defaults.bool(forKey: "nous.background.analysis.enabled"))
        XCTAssertTrue(defaults.bool(forKey: "nous.gemini.history.cache.enabled"))
        XCTAssertTrue(defaults.bool(forKey: "nous.assistant.thinking.enabled"))
        XCTAssertEqual(defaults.string(forKey: "nous.local.modelid"), "local-model")
        XCTAssertEqual(defaults.string(forKey: "nous.embedding.modelid"), "embed-model")
        XCTAssertNil(defaults.string(forKey: "nous.gemini.apikey"))
        XCTAssertNil(defaults.string(forKey: "nous.claude.apikey"))
        XCTAssertNil(defaults.string(forKey: "nous.openai.apikey"))
        XCTAssertEqual(secretStore.values["nous.gemini.apikey"], "gemini-key")
        XCTAssertNil(secretStore.values["nous.claude.apikey"])
        XCTAssertEqual(secretStore.values["nous.openai.apikey"], "openai-key")
    }

    func testLoadPreferencesClearsPersistedThinkingWhenDisabled() throws {
        let node = NousNode(type: .conversation, title: "Chat")
        try nodeStore.insertNode(node)
        try nodeStore.insertMessage(
            Message(nodeId: node.id, role: .assistant, content: "Answer", thinkingContent: "Private chain of thought")
        )

        _ = makeViewModel()

        let stored = try nodeStore.fetchMessages(nodeId: node.id)
        XCTAssertNil(stored.last?.thinkingContent)
    }

    func testUserDefaultsSecretStorePersistsAndClearsValues() {
        let suiteName = "debug-secret-store-\(UUID().uuidString)"
        let debugDefaults = UserDefaults(suiteName: suiteName)!
        debugDefaults.removePersistentDomain(forName: suiteName)
        let store = UserDefaultsSecretStore(defaults: debugDefaults, keyPrefix: "debug.")

        store.setString("abc123", for: "nous.gemini.apikey")
        XCTAssertEqual(store.string(for: "nous.gemini.apikey"), "abc123")

        store.setString(nil, for: "nous.gemini.apikey")
        XCTAssertNil(store.string(for: "nous.gemini.apikey"))
        debugDefaults.removePersistentDomain(forName: suiteName)
    }

    func testRuntimeModelSummariesShowOpenRouterForegroundAndJudgeModels() {
        let vm = makeViewModel()
        vm.selectedProvider = .openrouter
        vm.geminiApiKey = "gemini-key"

        XCTAssertEqual(
            vm.runtimeModelSummaries,
            [
                .init(
                    label: "Foreground chat",
                    model: "anthropic/claude-sonnet-4.6",
                    detail: "Uses OpenRouter for normal conversation turns."
                ),
                .init(
                    label: "Judge tasks",
                    model: "gemini-2.5-pro",
                    detail: "Uses Google AI Studio Gemini 2.5 Pro for judge checks while OpenRouter handles foreground chat."
                ),
                .init(
                    label: "Weekly reflections",
                    model: "gemini-2.5-pro",
                    detail: "Only runs when Background AI maintenance is turned on."
                )
            ]
        )
    }

    func testMakeJudgeLLMServiceUsesGeminiProForOpenRouterWhenGeminiKeyExists() {
        let vm = makeViewModel()
        vm.selectedProvider = .openrouter
        vm.openrouterApiKey = "test-key"
        vm.geminiApiKey = "gemini-key"

        let service = vm.makeJudgeLLMService()
        let gemini = service as? GeminiLLMService
        XCTAssertEqual(gemini?.model, "gemini-2.5-pro")
    }

    func testMakeJudgeLLMServiceReturnsNilForOpenRouterWhenGeminiKeyMissing() {
        let vm = makeViewModel()
        vm.selectedProvider = .openrouter
        vm.openrouterApiKey = "test-key"

        XCTAssertNil(vm.makeJudgeLLMService())
    }

    func testRuntimeModelSummariesShowLocalJudgeDisabledAndLoadState() {
        let vm = makeViewModel()
        vm.selectedProvider = .local
        vm.localModelId = "mlx-community/custom-local"

        XCTAssertEqual(
            vm.runtimeModelSummaries,
            [
                .init(
                    label: "Foreground chat",
                    model: "mlx-community/custom-local",
                    detail: "Selected for foreground chat, but the local model still needs to be loaded."
                ),
                .init(
                    label: "Judge tasks",
                    model: "Disabled",
                    detail: "Judge tasks are skipped on Local because the structured-output path is disabled there."
                ),
                .init(
                    label: "Weekly reflections",
                    model: "gemini-2.5-pro",
                    detail: "Only runs when Background AI maintenance is turned on."
                )
            ]
        )
    }

    func testVoiceModeAvailabilityRequiresOpenAIKey() {
        let vm = makeViewModel()

        XCTAssertFalse(vm.isVoiceModeAvailable)
        XCTAssertEqual(vm.voiceModeUnavailableReason, "Add an OpenAI API key to use Voice Mode.")

        vm.openaiApiKey = "  openai-key  "

        XCTAssertTrue(vm.isVoiceModeAvailable)
        XCTAssertNil(vm.voiceModeUnavailableReason)
    }

    private func makeViewModel() -> SettingsViewModel {
        SettingsViewModel(
            embeddingService: EmbeddingService(),
            localLLM: LocalLLMService(),
            nodeStore: nodeStore,
            defaults: defaults,
            secretStore: secretStore
        )
    }
}

private final class InMemorySecretStore: SecretStore {
    var values: [String: String] = [:]
    let storageDescription = "Stored in memory for tests."

    func string(for account: String) -> String? {
        values[account]
    }

    func setString(_ value: String?, for account: String) {
        if let value, !value.isEmpty {
            values[account] = value
        } else {
            values.removeValue(forKey: account)
        }
    }
}
