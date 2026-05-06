import XCTest
@testable import Nous

final class CognitionContractsTests: XCTestCase {
    func testCognitionFrameValidatesRecordsWithoutRawPromptText() throws {
        let frame = CognitionFrame(
            turnId: UUID(),
            conversationId: UUID(),
            assistantMessageId: UUID(),
            records: [
                CognitionOrganRecord(
                    organ: .coordinator,
                    label: "turn_steward",
                    status: .used,
                    reason: "ordinary_chat_full_memory",
                    evidenceRefs: [],
                    resourceIds: ["skill:00000000-0000-0000-0000-000000000001"],
                    riskFlags: []
                )
            ],
            createdAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNoThrow(try frame.validated())
        let encoded = String(data: try JSONEncoder().encode(frame), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("Help me plan"))
        XCTAssertFalse(encoded.contains("Assistant draft"))
    }

    func testCognitionFrameRejectsBlankRecordLabel() {
        let frame = CognitionFrame(
            turnId: UUID(),
            conversationId: UUID(),
            assistantMessageId: nil,
            records: [
                CognitionOrganRecord(
                    organ: .coordinator,
                    label: "   ",
                    status: .used,
                    reason: "ordinary_chat",
                    evidenceRefs: [],
                    resourceIds: [],
                    riskFlags: []
                )
            ]
        )

        XCTAssertThrowsError(try frame.validated()) { error in
            XCTAssertEqual(error as? CognitionValidationError, .emptySummary)
        }
    }

    func testLegacyTurnCognitionSnapshotDecodesWithoutCognitionFrame() throws {
        let json = """
        {
          "turnId": "00000000-0000-0000-0000-000000000101",
          "conversationId": "00000000-0000-0000-0000-000000000102",
          "assistantMessageId": "00000000-0000-0000-0000-000000000103",
          "promptLayers": ["anchor", "chat_mode"],
          "slowCognitionAttached": false,
          "reviewArtifactId": null,
          "reviewRiskFlags": [],
          "reviewConfidence": null,
          "recordedAt": 1000
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(TurnCognitionSnapshot.self, from: json)

        XCTAssertNil(snapshot.cognitionFrame)
        XCTAssertEqual(snapshot.promptLayers, ["anchor", "chat_mode"])
    }

    func testDurableArtifactRequiresEvidence() {
        let artifact = CognitionArtifact(
            organ: .patternAnalyst,
            title: "Weekly pattern",
            summary: "Alex keeps returning to the same product boundary.",
            confidence: 0.82,
            jurisdiction: .selfReflection,
            evidenceRefs: []
        )

        XCTAssertThrowsError(try artifact.validated()) { error in
            XCTAssertEqual(error as? CognitionValidationError, .missingEvidenceForDurableArtifact)
        }
    }

    func testTurnContextArtifactCanBeValidatedWithoutEvidence() throws {
        let artifact = CognitionArtifact(
            organ: .coordinator,
            title: "Turn-only stance",
            summary: "Answer gently in this turn.",
            confidence: 0.5,
            jurisdiction: .turnContext,
            evidenceRefs: []
        )

        XCTAssertNoThrow(try artifact.validated())
    }

    func testArtifactRejectsConfidenceOutsideZeroToOne() {
        let artifact = CognitionArtifact(
            organ: .behaviorLearner,
            title: "Bad confidence",
            summary: "Confidence cannot exceed one.",
            confidence: 1.1,
            jurisdiction: .shadowLearning,
            evidenceRefs: [
                CognitionEvidenceRef(source: .message, id: UUID().uuidString)
            ]
        )

        XCTAssertThrowsError(try artifact.validated()) { error in
            XCTAssertEqual(error as? CognitionValidationError, .confidenceOutOfBounds)
        }
    }

    func testArtifactRejectsBlankEvidenceRefIds() {
        let artifact = CognitionArtifact(
            organ: .patternAnalyst,
            title: "Blank evidence",
            summary: "Durable evidence refs must point at an auditable source.",
            confidence: 0.82,
            jurisdiction: .selfReflection,
            evidenceRefs: [
                CognitionEvidenceRef(source: .message, id: "   ")
            ]
        )

        XCTAssertThrowsError(try artifact.validated()) { error in
            XCTAssertEqual(error as? CognitionValidationError, .invalidEvidenceRef)
        }
    }

    func testContextPacketRejectsBlankEvidenceRefIdsWhenEvidenceIsRequired() {
        let packet = CognitionContextPacket(
            organ: .relationshipScout,
            currentAsk: "Find related nodes.",
            conversationId: UUID(),
            projectId: nil,
            currentNodeId: UUID(),
            threadSummary: "Current conversation is about Nous architecture.",
            jurisdiction: .graphMemory,
            evidenceRefs: [
                CognitionEvidenceRef(source: .node, id: "")
            ],
            allowedToolNames: [AgentToolNames.searchMemory],
            budget: CognitionBudget(maxInputCharacters: 2_000, maxOutputCharacters: 800, maxToolCalls: 2),
            privacyBoundary: .localOnly,
            outputContract: CognitionOutputContract(schemaName: "relationship_artifact", requiresEvidence: true, maxArtifacts: 1)
        )

        XCTAssertThrowsError(try packet.validated()) { error in
            XCTAssertEqual(error as? CognitionValidationError, .invalidEvidenceRef)
        }
    }

    func testContextPacketRejectsInvalidBudget() {
        let packet = CognitionContextPacket(
            organ: .relationshipScout,
            currentAsk: "Find related nodes.",
            conversationId: UUID(),
            projectId: nil,
            currentNodeId: UUID(),
            threadSummary: "Current conversation is about Nous architecture.",
            jurisdiction: .graphMemory,
            evidenceRefs: [],
            allowedToolNames: [AgentToolNames.searchMemory],
            budget: CognitionBudget(maxInputCharacters: 0, maxOutputCharacters: 800, maxToolCalls: 2),
            privacyBoundary: .localOnly,
            outputContract: CognitionOutputContract(schemaName: "relationship_artifact", requiresEvidence: true, maxArtifacts: 1)
        )

        XCTAssertThrowsError(try packet.validated()) { error in
            XCTAssertEqual(error as? CognitionValidationError, .invalidBudget)
        }
    }
}
