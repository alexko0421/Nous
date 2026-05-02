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
        vm.openRouterWebSearchEnabled = false
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
        XCTAssertEqual(defaults.object(forKey: "nous.openrouter.websearch.enabled") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "nous.local.modelid"), "local-model")
        XCTAssertEqual(defaults.string(forKey: "nous.embedding.modelid"), "embed-model")
        XCTAssertNil(defaults.string(forKey: "nous.gemini.apikey"))
        XCTAssertNil(defaults.string(forKey: "nous.claude.apikey"))
        XCTAssertNil(defaults.string(forKey: "nous.openai.apikey"))
        XCTAssertEqual(secretStore.values["nous.gemini.apikey"], "gemini-key")
        XCTAssertNil(secretStore.values["nous.claude.apikey"])
        XCTAssertEqual(secretStore.values["nous.openai.apikey"], "openai-key")
    }

    func testOpenRouterWebSearchPreferenceDefaultsOnAndPersists() {
        let vm = makeViewModel()
        XCTAssertTrue(vm.openRouterWebSearchEnabled)

        vm.openRouterWebSearchEnabled = false
        vm.savePreferences()

        let reloaded = makeViewModel()
        XCTAssertFalse(reloaded.openRouterWebSearchEnabled)
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

    func testRuntimeModelSummariesShowOpenRouterJudgeTargetWhenGeminiKeyMissing() {
        let vm = makeViewModel()
        vm.selectedProvider = .openrouter

        let judge = vm.runtimeModelSummaries.first { $0.label == "Judge tasks" }

        XCTAssertEqual(judge?.model, "gemini-2.5-pro")
        XCTAssertEqual(
            judge?.detail,
            "Missing Gemini API key; judge checks are currently skipped while OpenRouter handles foreground chat."
        )
    }

    func testSupplementalGeminiKeyFieldShowsWhenForegroundProviderIsNotGemini() {
        let vm = makeViewModel()

        vm.selectedProvider = .openrouter
        XCTAssertTrue(vm.shouldShowSupplementalGeminiKeyField)

        vm.selectedProvider = .local
        XCTAssertTrue(vm.shouldShowSupplementalGeminiKeyField)

        vm.selectedProvider = .gemini
        XCTAssertFalse(vm.shouldShowSupplementalGeminiKeyField)
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

    func testMakeLLMServiceConfiguresOpenRouterWebSearch() {
        let vm = makeViewModel()
        vm.selectedProvider = .openrouter
        vm.openrouterApiKey = "test-key"
        vm.openRouterWebSearchEnabled = true

        let enabled = vm.makeLLMService() as? OpenRouterLLMService
        XCTAssertEqual(enabled?.webSearchEnabled, true)

        vm.openRouterWebSearchEnabled = false
        let disabled = vm.makeLLMService() as? OpenRouterLLMService
        XCTAssertEqual(disabled?.webSearchEnabled, false)
    }

    func testMakeLLMServiceCanDisableOpenRouterWebSearchForBackgroundTasks() {
        let vm = makeViewModel()
        vm.selectedProvider = .openrouter
        vm.openrouterApiKey = "test-key"
        vm.openRouterWebSearchEnabled = true

        let service = vm.makeLLMService(openRouterWebSearchEnabled: false) as? OpenRouterLLMService

        XCTAssertEqual(service?.webSearchEnabled, false)
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

    func testVoicePreferencesPersistInUserDefaults() {
        let vm = makeViewModel()
        vm.voiceOutputVoice = .marin
        vm.voiceLanguage = .mandarin

        vm.savePreferences()

        let reloaded = makeViewModel()
        XCTAssertEqual(reloaded.voiceOutputVoice, .marin)
        XCTAssertEqual(reloaded.voiceLanguage, .mandarin)
        XCTAssertEqual(defaults.string(forKey: "nous.voice.outputVoice"), "marin")
        XCTAssertEqual(defaults.string(forKey: "nous.voice.language"), "mandarin")
    }

    func testVoiceLanguageOptionsDoNotIncludeTaiwaneseMandarin() {
        XCTAssertEqual(
            VoiceLanguage.allCases.map(\.rawValue),
            ["automatic", "cantonese", "mandarin", "english"]
        )
        XCTAssertFalse(VoiceLanguage.allCases.map(\.displayName).contains("台式普通話"))
    }

    func testLegacyTaiwaneseMandarinPreferenceFallsBackToAutomatic() {
        defaults.set("taiwanese_mandarin", forKey: "nous.voice.language")

        let vm = makeViewModel()

        XCTAssertEqual(vm.voiceLanguage, .automatic)
    }

    func testPreviewVoiceUsesSelectedVoiceLanguageAndOpenAIKey() async {
        let previewer = FakeVoicePreviewer()
        let vm = makeViewModel(voicePreviewer: previewer)
        vm.openaiApiKey = "  openai-key  "
        vm.voiceOutputVoice = .verse
        vm.voiceLanguage = .cantonese

        await vm.previewSelectedVoice()

        XCTAssertEqual(previewer.requests, [
            .init(apiKey: "openai-key", voice: .verse, language: .cantonese)
        ])
        XCTAssertNil(vm.voicePreviewError)
    }

    private func makeViewModel(voicePreviewer: VoicePreviewing = NullVoicePreviewer()) -> SettingsViewModel {
        SettingsViewModel(
            embeddingService: EmbeddingService(),
            localLLM: LocalLLMService(),
            nodeStore: nodeStore,
            defaults: defaults,
            secretStore: secretStore,
            voicePreviewer: voicePreviewer
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

private final class FakeVoicePreviewer: VoicePreviewing {
    struct Request: Equatable {
        let apiKey: String
        let voice: VoiceOutputVoice
        let language: VoiceLanguage
    }

    var requests: [Request] = []

    func preview(apiKey: String, voice: VoiceOutputVoice, language: VoiceLanguage) async throws {
        requests.append(.init(apiKey: apiKey, voice: voice, language: language))
    }
}

private struct NullVoicePreviewer: VoicePreviewing {
    func preview(apiKey: String, voice: VoiceOutputVoice, language: VoiceLanguage) async throws {}
}
