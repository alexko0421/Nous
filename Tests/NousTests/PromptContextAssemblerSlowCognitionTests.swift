import XCTest
@testable import Nous

final class PromptContextAssemblerSlowCognitionTests: XCTestCase {
    func testSlowCognitionSignalRendersInVolatilePromptOnlyAndClampsToOneArtifact() {
        let relevant = cognitionArtifact(
            title: "Product boundary tension",
            summary: "Alex keeps saying Nous should be a long-term mind, not an agent workflow platform.",
            suggestedSurfacing: "Mention the product boundary only if Alex asks about public positioning."
        )
        let secondRelevant = cognitionArtifact(
            title: "MCP connector caution",
            summary: "External tools should be senses and hands, not the product identity.",
            suggestedSurfacing: "Use this if the current turn is about MCP."
        )

        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "If we go public, should MCP be the main identity?",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            slowCognitionArtifacts: [relevant, secondRelevant]
        )

        XCTAssertFalse(slice.stable.contains("SLOW COGNITION SIGNAL"))
        XCTAssertTrue(slice.volatile.contains("SLOW COGNITION SIGNAL:"))
        XCTAssertTrue(slice.volatile.contains(relevant.summary))
        XCTAssertFalse(slice.volatile.contains(secondRelevant.summary))
        XCTAssertTrue(slice.volatile.contains("Use this as a sourced, optional signal"))
        XCTAssertTrue(slice.volatile.contains(relevant.evidenceRefs[0].id))
    }

    func testSlowCognitionSignalSkipsIrrelevantArtifacts() {
        let artifact = cognitionArtifact(
            title: "Voice transcript behavior",
            summary: "Alex tends to summarize spoken thoughts after voice sessions.",
            suggestedSurfacing: "Use only for voice-mode recaps."
        )

        let slice = PromptContextAssembler.assembleContext(
            chatMode: .companion,
            currentUserInput: "Should MCP be part of our public positioning?",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            slowCognitionArtifacts: [artifact]
        )

        XCTAssertFalse(slice.volatile.contains("SLOW COGNITION SIGNAL"))
    }

    func testGovernanceTraceIncludesSlowCognitionLayerOnlyWhenSignalSelected() {
        let artifact = cognitionArtifact(
            title: "Long-term mind",
            summary: "Nous should be a long-term mind rather than a multi-agent tool.",
            suggestedSurfacing: nil
        )

        let traceWithSignal = PromptContextAssembler.governanceTrace(
            chatMode: .companion,
            currentUserInput: "How should we describe this long-term mind publicly?",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            slowCognitionArtifacts: [artifact]
        )
        let traceWithoutSignal = PromptContextAssembler.governanceTrace(
            chatMode: .companion,
            currentUserInput: "Unrelated hello",
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil,
            slowCognitionArtifacts: [artifact]
        )

        XCTAssertTrue(traceWithSignal.promptLayers.contains("slow_cognition"))
        XCTAssertFalse(traceWithoutSignal.promptLayers.contains("slow_cognition"))
    }

    func testSelectorMatchesMixedChineseCantonesePhraseOverlap() throws {
        let artifact = cognitionArtifact(
            title: "长期心智系统",
            summary: "Nous should be a长期嘅心智系统, not an agent workflow platform.",
            suggestedSurfacing: "Use when Alex talks about long-term mind direction."
        )

        let selected = CognitionArtifactSelector.selectForChat(
            currentInput: "我哋要认真做长期心智，唔系短期 agent 工具",
            artifacts: [artifact]
        )

        XCTAssertEqual(try XCTUnwrap(selected).id, artifact.id)
    }

    private func cognitionArtifact(
        title: String,
        summary: String,
        suggestedSurfacing: String?
    ) -> CognitionArtifact {
        CognitionArtifact(
            organ: .patternAnalyst,
            title: title,
            summary: summary,
            confidence: 0.82,
            jurisdiction: .selfReflection,
            evidenceRefs: [
                CognitionEvidenceRef(source: .message, id: UUID().uuidString, quote: "source quote")
            ],
            suggestedSurfacing: suggestedSurfacing
        )
    }
}
