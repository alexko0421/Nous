import XCTest
@testable import Nous

final class PromptContextAssemblerSoftHardCalibrationTests: XCTestCase {
    func testPushbackAddsSoftHardCalibrationGuard() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "你太 harsh 啦，我觉得你刚才好似为咗反对而反对。",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(slice.volatile.contains("SOFT-HARD CALIBRATION CHECK"))
        XCTAssertTrue(slice.volatile.contains("repair tone before defending the point"))
        XCTAssertTrue(slice.volatile.contains("Do not use \"my original point still stands\" as a shortcut"))
        XCTAssertTrue(slice.volatile.contains("Keep only evidence-backed tension"))
        XCTAssertTrue(slice.volatile.contains("If the original claim was weak, soften or retract it"))
    }

    func testOrdinaryQuestionDoesNotAddSoftHardCalibrationGuard() {
        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "今日做边个 feature 先会最有 leverage？",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertFalse(slice.volatile.contains("SOFT-HARD CALIBRATION CHECK"))
    }

    func testGovernanceTraceIncludesSoftHardLayerOnlyWhenNeeded() {
        let traceWithPushback = PromptContextAssembler.governanceTrace(
            chatMode: .strategist,
            currentUserInput: "你啱啱讲得太硬啦，但我又怕你变到太顺我。",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )
        let traceWithoutPushback = PromptContextAssembler.governanceTrace(
            chatMode: .strategist,
            currentUserInput: "帮我睇下今日应该收边个口。",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )

        XCTAssertTrue(traceWithPushback.promptLayers.contains("soft_hard_calibration_guard"))
        XCTAssertFalse(traceWithoutPushback.promptLayers.contains("soft_hard_calibration_guard"))
    }
}
