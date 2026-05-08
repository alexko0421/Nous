import XCTest
@testable import Nous

@MainActor
final class SettingsViewModelLLMRoutingTests: XCTestCase {

    func test_foregroundPurpose_matchesLegacyMakeLLMService_openrouter() {
        let vm = SettingsViewModel.testFixture(
            provider: .openrouter,
            openrouterApiKey: "test-or"
        )
        let legacy = vm.makeLLMService(openRouterWebSearchEnabled: false)
        let routed = vm.makeLLMService(
            for: .foreground(mode: .companion, quickAction: nil),
            openRouterWebSearchEnabled: false
        )
        XCTAssertEqual(type(of: legacy!) == type(of: routed!), true)
    }

    func test_judgePurpose_matchesLegacyMakeJudgeLLMService_openrouter() {
        let vm = SettingsViewModel.testFixture(
            provider: .openrouter,
            openrouterApiKey: "test-or"
        )
        let legacy = vm.makeJudgeLLMService()
        let routed = vm.makeLLMService(for: .judge)
        XCTAssertEqual(type(of: legacy!) == type(of: routed!), true)
    }

    func test_reflectionPurpose_returnsGeminiServiceWhenKeyPresent() {
        let vm = SettingsViewModel.testFixture(
            provider: .openrouter, // intentionally NOT gemini
            openrouterApiKey: "test-or",
            geminiApiKey: "test-gemini"
        )
        let routed = vm.makeLLMService(for: .reflection)
        XCTAssertNotNil(routed)
        XCTAssertTrue(routed is GeminiLLMService)
    }

    func test_reflectionPurpose_returnsNilWhenGeminiKeyMissing() {
        let vm = SettingsViewModel.testFixture(
            provider: .openrouter,
            openrouterApiKey: "test-or",
            geminiApiKey: ""
        )
        XCTAssertNil(vm.makeLLMService(for: .reflection))
    }

    func test_provider_for_judge_matchesSelectedProvider() {
        let vm = SettingsViewModel.testFixture(provider: .openrouter, openrouterApiKey: "k")
        XCTAssertEqual(vm.provider(for: .judge), .openrouter)
    }

    func test_provider_for_reflection_isAlwaysGemini() {
        let vm = SettingsViewModel.testFixture(provider: .openrouter, openrouterApiKey: "k", geminiApiKey: "g")
        XCTAssertEqual(vm.provider(for: .reflection), .gemini)
    }
}

// MARK: - Test fixture

extension SettingsViewModel {
    @MainActor
    static func testFixture(
        provider: LLMProvider = .openrouter,
        openrouterApiKey: String = "",
        geminiApiKey: String = "",
        claudeApiKey: String = "",
        openaiApiKey: String = ""
    ) -> SettingsViewModel {
        let suiteName = "settings-routing-fixture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let nodeStore = try! NodeStore(path: ":memory:")
        let secretStore = VolatileSecretStore()

        let vm = SettingsViewModel(
            embeddingService: EmbeddingService(),
            localLLM: LocalLLMService(),
            nodeStore: nodeStore,
            defaults: defaults,
            secretStore: secretStore
        )

        vm.selectedProvider = provider
        vm.openrouterApiKey = openrouterApiKey
        vm.geminiApiKey = geminiApiKey
        vm.claudeApiKey = claudeApiKey
        vm.openaiApiKey = openaiApiKey

        return vm
    }
}
