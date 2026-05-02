import XCTest
@testable import Nous

final class CognitionArtifactAdapterTests: XCTestCase {
    func testWeeklyReflectionAdapterProducesPatternAnalystArtifactsWithMessageEvidence() throws {
        let run = ReflectionRun(
            projectId: nil,
            weekStart: Date(timeIntervalSince1970: 100),
            weekEnd: Date(timeIntervalSince1970: 200),
            status: .success
        )
        let claim = ReflectionClaim(
            runId: run.id,
            claim: "Across the week, Alex kept returning to product boundaries.",
            confidence: 0.84,
            whyNonObvious: "It cut across separate conversations."
        )
        let firstMessageId = UUID()
        let secondMessageId = UUID()
        let artifacts = WeeklyReflectionCognitionAdapter.artifacts(
            run: run,
            claims: [claim],
            evidence: [
                ReflectionEvidence(reflectionId: claim.id, messageId: firstMessageId),
                ReflectionEvidence(reflectionId: claim.id, messageId: secondMessageId)
            ]
        )

        let artifact = try XCTUnwrap(artifacts.first)
        XCTAssertEqual(artifact.organ, .patternAnalyst)
        XCTAssertEqual(artifact.jurisdiction, .selfReflection)
        XCTAssertEqual(artifact.summary, claim.claim)
        XCTAssertEqual(artifact.confidence, claim.confidence)
        XCTAssertEqual(Set(artifact.evidenceRefs.map(\.id)), Set([firstMessageId.uuidString, secondMessageId.uuidString]))
        XCTAssertNoThrow(try artifact.validated())
    }

    func testShadowPatternAdapterProducesBehaviorLearnerArtifact() throws {
        let messageId = UUID()
        let pattern = ShadowLearningPattern(
            id: UUID(),
            userId: "alex",
            kind: .thinkingMove,
            label: "pain_test_for_product_scope",
            summary: "Alex repeatedly uses the pain test for product scope.",
            promptFragment: "Ask whether absence would genuinely hurt.",
            triggerHint: "product scope pain test",
            confidence: 0.76,
            weight: 0.62,
            status: .strong,
            evidenceMessageIds: [messageId],
            firstSeenAt: Date(timeIntervalSince1970: 10),
            lastSeenAt: Date(timeIntervalSince1970: 20),
            lastReinforcedAt: nil,
            lastCorrectedAt: nil,
            activeFrom: nil,
            activeUntil: nil
        )

        let artifact = try XCTUnwrap(ShadowLearningCognitionAdapter.artifact(from: pattern))

        XCTAssertEqual(artifact.organ, .behaviorLearner)
        XCTAssertEqual(artifact.jurisdiction, .shadowLearning)
        XCTAssertEqual(artifact.title, pattern.label)
        XCTAssertEqual(artifact.suggestedSurfacing, pattern.promptFragment)
        XCTAssertEqual(artifact.evidenceRefs.first?.source, .message)
        XCTAssertEqual(artifact.evidenceRefs.first?.id, messageId.uuidString)
        XCTAssertNoThrow(try artifact.validated())
    }

    func testShadowPatternAdapterSkipsPatternWithoutEvidence() {
        let pattern = ShadowLearningPattern(
            id: UUID(),
            userId: "alex",
            kind: .thinkingMove,
            label: "pain_test_for_product_scope",
            summary: "Alex repeatedly uses the pain test for product scope.",
            promptFragment: "Ask whether absence would genuinely hurt.",
            triggerHint: "product scope pain test",
            confidence: 0.76,
            weight: 0.62,
            status: .strong,
            evidenceMessageIds: [],
            firstSeenAt: Date(timeIntervalSince1970: 10),
            lastSeenAt: Date(timeIntervalSince1970: 20),
            lastReinforcedAt: nil,
            lastCorrectedAt: nil,
            activeFrom: nil,
            activeUntil: nil
        )

        let artifact: CognitionArtifact? = ShadowLearningCognitionAdapter.artifact(from: pattern)

        XCTAssertNil(artifact)
    }

    func testGalaxyRelationAdapterProducesRelationshipScoutArtifact() throws {
        let source = NousNode(type: .note, title: "Scope boundary", content: "Do not build a workflow suite.")
        let target = NousNode(type: .conversation, title: "Agent architecture", content: "Use tools as organs, not product identity.")
        let sourceAtomId = UUID()
        let targetAtomId = UUID()
        let verdict = GalaxyRelationVerdict(
            relationKind: .supports,
            confidence: 0.91,
            explanation: "The older product boundary supports the new agent architecture framing.",
            sourceEvidence: "Do not build a workflow suite.",
            targetEvidence: "Use tools as organs.",
            sourceAtomId: sourceAtomId,
            targetAtomId: targetAtomId
        )

        let artifact = GalaxyRelationCognitionAdapter.artifact(
            verdict: verdict,
            source: source,
            target: target
        )

        XCTAssertEqual(artifact.organ, .relationshipScout)
        XCTAssertEqual(artifact.jurisdiction, .graphMemory)
        XCTAssertTrue(artifact.summary.contains(verdict.explanation))
        XCTAssertEqual(artifact.confidence, Double(verdict.confidence), accuracy: 0.0001)
        XCTAssertTrue(artifact.evidenceRefs.contains(CognitionEvidenceRef(source: .node, id: source.id.uuidString, quote: verdict.sourceEvidence)))
        XCTAssertTrue(artifact.evidenceRefs.contains(CognitionEvidenceRef(source: .node, id: target.id.uuidString, quote: verdict.targetEvidence)))
        XCTAssertTrue(artifact.evidenceRefs.contains(CognitionEvidenceRef(source: .memoryAtom, id: sourceAtomId.uuidString)))
        XCTAssertTrue(artifact.evidenceRefs.contains(CognitionEvidenceRef(source: .memoryAtom, id: targetAtomId.uuidString)))
        XCTAssertNoThrow(try artifact.validated())
    }
}
