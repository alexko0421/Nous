import XCTest
@testable import Nous

final class PromptContextAssemblerTeachingExplanationTests: XCTestCase {
    func testSimplificationRequestAddsTeachingExplanationFidelityGuard() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "你讲得太复杂啦，可唔可以用最简单方法解释 compound sentence 同 complex sentence 点分？",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(slice.volatile.contains("TEACHING EXPLANATION FIDELITY CHECK"))
        XCTAssertTrue(slice.volatile.contains("simplify without becoming lossy"))
        XCTAssertTrue(slice.volatile.contains("domain's exact distinction"))
        XCTAssertTrue(slice.volatile.contains("dry equation"))
        XCTAssertTrue(slice.volatile.contains("not a worksheet"))
        XCTAssertTrue(slice.volatile.contains("Feynman-style check"))
        XCTAssertTrue(slice.volatile.contains("invite Alex to explain it back"))
        XCTAssertTrue(slice.volatile.contains("not a mandatory study ritual"))
    }

    func testOrdinaryDecisionDoesNotAddTeachingExplanationGuard() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .strategist,
            currentUserInput: "我今日应该继续做 app 定系先去休息？",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertFalse(slice.volatile.contains("TEACHING EXPLANATION FIDELITY CHECK"))
    }

    func testEmotionalLearningRequestKeepsSupportBeforeStudyTechnique() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "我今日好低落，英文又学唔入，觉得自己好蠢。你简单解释一下 bounded attention 同 free attention。",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(slice.volatile.contains("support the feeling before teaching"))
        XCTAssertTrue(slice.volatile.contains("skip the Feynman-style check"))
        XCTAssertTrue(slice.volatile.contains("Do not expose method names"))
    }

    func testGovernanceTraceIncludesTeachingExplanationLayerOnlyWhenNeeded() {
        let traceWithTeaching = PromptContextAssembler.governanceTrace(
            chatMode: .companion,
            currentUserInput: "今日英文课又讲到 complex 同 compound，点样先唔会搞乱？",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )
        let traceWithoutTeaching = PromptContextAssembler.governanceTrace(
            chatMode: .companion,
            currentUserInput: "今日有少少攰，想静一静。",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(traceWithTeaching.promptLayers.contains("teaching_explanation_guard"))
        XCTAssertFalse(traceWithoutTeaching.promptLayers.contains("teaching_explanation_guard"))
    }
}
