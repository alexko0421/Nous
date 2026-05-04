import XCTest
@testable import Nous

final class PromptContextAssemblerShadowLearningTests: XCTestCase {
    func testShadowHintsRenderInVolatilePromptOnlyAndClampToThreeBullets() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "Should we build this?",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            shadowLearningHints: [
                "For product scope, ask whether absence would genuinely hurt.",
                "Before recommending, name the worst version of the decision.",
                "Prefer concrete tradeoffs over generic encouragement.",
                "This fourth hint should be clamped out."
            ]
        )

        XCTAssertFalse(slice.stable.contains("SHADOW THINKING HINTS"))
        XCTAssertFalse(slice.stable.contains("For product scope"))
        XCTAssertTrue(slice.volatile.contains("SHADOW THINKING HINTS:"))
        XCTAssertTrue(slice.volatile.contains("- For product scope"))
        XCTAssertTrue(slice.volatile.contains("- Before recommending"))
        XCTAssertTrue(slice.volatile.contains("- Prefer concrete tradeoffs"))
        XCTAssertFalse(slice.volatile.contains("This fourth hint"))
        XCTAssertTrue(slice.volatile.contains("Do not mention the shadow profile, learning system"))
    }

    func testGovernanceTraceIncludesShadowLearningLayerOnlyWhenHintsExist() {
        let traceWithHints = PromptContextAssembler.governanceTrace(
            chatMode: .companion,
            currentUserInput: "Should we build this?",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            shadowLearningHints: ["Use pain test."]
        )
        let traceWithoutHints = PromptContextAssembler.governanceTrace(
            chatMode: .companion,
            currentUserInput: "Should we build this?",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(traceWithHints.promptLayers.contains("shadow_learning"))
        XCTAssertFalse(traceWithoutHints.promptLayers.contains("shadow_learning"))
    }
}
