import XCTest
@testable import Nous

final class PromptGovernanceTraceTests: XCTestCase {
    func testDecodesLegacyJSONWithoutTurnSteward() throws {
        let json = """
        {
          "promptLayers": ["anchor", "chat_mode"],
          "evidenceAttached": false,
          "safetyPolicyInvoked": false,
          "highRiskQueryDetected": false
        }
        """.data(using: .utf8)!

        let trace = try JSONDecoder().decode(PromptGovernanceTrace.self, from: json)

        XCTAssertEqual(trace.promptLayers, ["anchor", "chat_mode"])
        XCTAssertNil(trace.turnSteward)
    }

    func testEncodesAndDecodesTurnStewardTrace() throws {
        let stewardTrace = TurnStewardTrace(
            route: .brainstorm,
            memoryPolicy: .lean,
            challengeStance: .useSilently,
            responseShape: .listDirections,
            projectSignalKind: nil,
            source: .deterministic,
            reason: "explicit brainstorm cue"
        )
        let trace = PromptGovernanceTrace(
            promptLayers: ["anchor", "turn_steward"],
            evidenceAttached: false,
            safetyPolicyInvoked: false,
            highRiskQueryDetected: false,
            turnSteward: stewardTrace
        )

        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(PromptGovernanceTrace.self, from: data)

        XCTAssertEqual(decoded.turnSteward, stewardTrace)
    }

    func testGovernanceTraceAddsTurnStewardLayer() {
        let stewardTrace = TurnStewardTrace(
            route: .direction,
            memoryPolicy: .full,
            challengeStance: .surfaceTension,
            responseShape: .narrowNextStep,
            projectSignalKind: nil,
            source: .deterministic,
            reason: "explicit direction cue"
        )

        let trace = ChatViewModel.governanceTrace(
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            turnSteward: stewardTrace
        )

        XCTAssertTrue(trace.promptLayers.contains("turn_steward"))
        XCTAssertEqual(trace.turnSteward, stewardTrace)
    }
}
