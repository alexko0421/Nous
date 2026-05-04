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
        XCTAssertEqual(traceWithSignal.slowCognitionTrace?.artifactId, artifact.id)
        XCTAssertEqual(traceWithSignal.slowCognitionTrace?.evidenceRefIds, artifact.evidenceRefs.map(\.id))
        XCTAssertEqual(traceWithSignal.slowCognitionTrace?.evidenceRefCount, artifact.evidenceRefs.count)
        XCTAssertFalse(traceWithoutSignal.promptLayers.contains("slow_cognition"))
        XCTAssertNil(traceWithoutSignal.slowCognitionTrace)
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

    func testSlowCognitionPromptFormatterCapsLongFieldsAndQuotes() {
        let longTitle = String(repeating: "Title ", count: 80)
        let longSummary = String(repeating: "Summary about a long-term mind system. ", count: 80)
        let longSuggestion = String(repeating: "Mention only if it helps. ", count: 80)
        let longQuote = String(repeating: "Evidence quote with private context. ", count: 80)
        let artifact = CognitionArtifact(
            organ: .patternAnalyst,
            title: longTitle,
            summary: longSummary,
            confidence: 0.82,
            jurisdiction: .selfReflection,
            evidenceRefs: [
                CognitionEvidenceRef(source: .message, id: UUID().uuidString, quote: longQuote),
                CognitionEvidenceRef(source: .message, id: UUID().uuidString, quote: longQuote),
                CognitionEvidenceRef(source: .message, id: UUID().uuidString, quote: longQuote),
                CognitionEvidenceRef(source: .message, id: UUID().uuidString, quote: longQuote)
            ],
            suggestedSurfacing: longSuggestion
        )

        let block = CognitionPromptFormatter.volatileBlock(for: artifact)

        XCTAssertLessThanOrEqual(block.count, 1_800)
        XCTAssertFalse(block.contains(longTitle))
        XCTAssertFalse(block.contains(longSummary))
        XCTAssertFalse(block.contains(longSuggestion))
        XCTAssertFalse(block.contains(longQuote))
        XCTAssertTrue(block.contains("..."))
        XCTAssertTrue(block.contains("Use this as a sourced, optional signal"))
    }

    func testSlowCognitionPromptFormatterCapsLongEvidenceIds() {
        let longEvidenceId = String(repeating: "external-resource-id-", count: 30)
        let artifact = CognitionArtifact(
            organ: .relationshipScout,
            title: "Connector signal",
            summary: "External evidence IDs should not dominate the volatile prompt block.",
            confidence: 0.82,
            jurisdiction: .graphMemory,
            evidenceRefs: [
                CognitionEvidenceRef(source: .externalResource, id: longEvidenceId, quote: "Short quote")
            ]
        )

        let block = CognitionPromptFormatter.volatileBlock(for: artifact)

        XCTAssertLessThanOrEqual(block.count, 1_800)
        XCTAssertFalse(block.contains(longEvidenceId))
        XCTAssertTrue(block.contains("external_resource:external-resource-id"))
        XCTAssertTrue(block.contains("Use this as a sourced, optional signal"))
    }

    func testSlowCognitionPromptFormatterPreservesSafetyInstructionUnderWorstCaseBudget() {
        let longEvidenceId = String(repeating: "external-resource-id-", count: 30)
        let longQuote = String(repeating: "Evidence quote with private context. ", count: 80)
        let artifact = CognitionArtifact(
            organ: .externalSense,
            title: String(repeating: "Connector signal ", count: 30),
            summary: String(repeating: "External evidence should stay bounded and sourced. ", count: 50),
            confidence: 0.82,
            jurisdiction: .externalResource,
            evidenceRefs: [
                CognitionEvidenceRef(source: .externalResource, id: longEvidenceId, quote: longQuote),
                CognitionEvidenceRef(source: .externalResource, id: longEvidenceId, quote: longQuote),
                CognitionEvidenceRef(source: .externalResource, id: longEvidenceId, quote: longQuote),
                CognitionEvidenceRef(source: .externalResource, id: longEvidenceId, quote: longQuote)
            ],
            suggestedSurfacing: String(repeating: "Mention only if it helps. ", count: 80)
        )

        let block = CognitionPromptFormatter.volatileBlock(for: artifact)

        XCTAssertLessThanOrEqual(block.count, 1_800)
        XCTAssertTrue(block.contains("Use this as a sourced, optional signal"))
        XCTAssertTrue(block.contains("do not describe internal organs"))
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
