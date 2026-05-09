import XCTest
@testable import Nous

final class TurnCognitionInspectorFeedTests: XCTestCase {
    func testRowsShowRuntimeCognitionStatusNewestFirst() {
        let now = Date(timeIntervalSince1970: 10_000)
        let older = snapshot(
            suffix: "301",
            promptLayers: ["anchor", "chat_mode"],
            slowCognitionAttached: false,
            recordedAt: now.addingTimeInterval(-7_200)
        )
        let newer = snapshot(
            suffix: "302",
            promptLayers: ["anchor", "chat_mode", "slow_cognition"],
            slowCognitionAttached: true,
            slowCognitionArtifactId: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
            slowCognitionEvidenceRefCount: 2,
            reviewArtifactId: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
            reviewRiskFlags: ["unsupported_memory_reference", "weak_reasoning"],
            conversationRecoveryReason: "missing_current_node",
            conversationRecoveryRebasedMessageCount: 1,
            recordedAt: now.addingTimeInterval(-300)
        )

        let rows = TurnCognitionInspectorFeedFormatting.rows(from: [older, newer], now: now)

        XCTAssertEqual(rows.map(\.turnId), [newer.turnId, older.turnId])
        XCTAssertEqual(rows[0].relativeTime, "5m ago")
        XCTAssertEqual(rows[0].slowCognitionStatus, "Sourced slow signal")
        XCTAssertEqual(rows[0].slowCognitionDetail, "2 evidence refs")
        XCTAssertEqual(rows[0].reviewStatus, "Reviewed: 2 risk flags")
        XCTAssertEqual(rows[0].recoveryStatus, "Recovered: missing current node, 1 rebased message")
        XCTAssertEqual(rows[0].riskSummary, "unsupported memory reference, weak reasoning")
        XCTAssertEqual(rows[0].promptLayerSummary, "3 prompt layers")
        XCTAssertTrue(rows[0].hasSlowSource)
        XCTAssertTrue(rows[0].hasReviewRisk)
        XCTAssertTrue(rows[0].hadConversationRecovery)
    }

    func testRowsCallOutUnsourcedSlowSignalAndClearReview() {
        let now = Date(timeIntervalSince1970: 10_000)
        let row = TurnCognitionInspectorFeedFormatting.rows(
            from: [
                snapshot(
                    suffix: "303",
                    promptLayers: ["anchor", "chat_mode", "slow_cognition"],
                    slowCognitionAttached: true,
                    slowCognitionArtifactId: nil,
                    slowCognitionEvidenceRefCount: 0,
                    reviewArtifactId: UUID(uuidString: "00000000-0000-0000-0000-000000000403")!,
                    reviewRiskFlags: [],
                    reviewConfidence: 0.74,
                    recordedAt: now.addingTimeInterval(-45)
                )
            ],
            now: now
        )[0]

        XCTAssertEqual(row.relativeTime, "45s ago")
        XCTAssertEqual(row.slowCognitionStatus, "Unsourced slow signal")
        XCTAssertEqual(row.slowCognitionDetail, "Missing artifact or evidence refs")
        XCTAssertEqual(row.reviewStatus, "Reviewed: clear, c 0.74")
        XCTAssertEqual(row.recoveryStatus, "No recovery")
        XCTAssertEqual(row.riskSummary, "No risk flags")
        XCTAssertEqual(row.promptLayerSummary, "3 prompt layers")
        XCTAssertFalse(row.hasSlowSource)
        XCTAssertFalse(row.hasReviewRisk)
        XCTAssertFalse(row.hadConversationRecovery)
    }

    func testTelemetryBuildsInspectorFeedFromRecentWindow() {
        let telemetry = makeTelemetry()
        let now = Date(timeIntervalSince1970: 10_000)
        let first = snapshot(
            suffix: "304",
            promptLayers: ["anchor"],
            slowCognitionAttached: false,
            recordedAt: now.addingTimeInterval(-120)
        )
        let second = snapshot(
            suffix: "305",
            promptLayers: ["anchor", "slow_cognition"],
            slowCognitionAttached: true,
            slowCognitionArtifactId: UUID(uuidString: "00000000-0000-0000-0000-000000000405")!,
            slowCognitionEvidenceRefCount: 1,
            recordedAt: now.addingTimeInterval(-30)
        )

        telemetry.recordTurnCognitionSnapshot(first)
        telemetry.recordTurnCognitionSnapshot(second)

        let feed = telemetry.turnCognitionInspectorFeed(limit: 1, now: now)

        XCTAssertEqual(feed.summary.totalTurnCount, 2)
        XCTAssertEqual(feed.rows.map(\.turnId), [second.turnId])
        XCTAssertEqual(feed.rows.first?.relativeTime, "30s ago")
        XCTAssertEqual(telemetry.turnCognitionInspectorFeed(limit: 0, now: now).rows, [])
    }

    func testRowsDoNotExposePromptText() {
        let now = Date(timeIntervalSince1970: 10_000)
        let frame = CognitionFrame(
            turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000306")!,
            conversationId: UUID(uuidString: "00000000-0000-0000-0000-000000001306")!,
            assistantMessageId: UUID(uuidString: "00000000-0000-0000-0000-000000002306")!,
            records: [
                CognitionOrganRecord(
                    organ: .reviewer,
                    label: "reviewer",
                    status: .failed,
                    reason: "Help me plan\nAssistant draft"
                )
            ],
            createdAt: now
        )
        let rows = TurnCognitionInspectorFeedFormatting.rows(
            from: [
                snapshot(
                    suffix: "306",
                    promptLayers: ["anchor", "chat_mode", "slow_cognition"],
                    slowCognitionAttached: true,
                    slowCognitionArtifactId: UUID(uuidString: "00000000-0000-0000-0000-000000000406")!,
                    slowCognitionEvidenceRefCount: 1,
                    reviewRiskFlags: ["unsupported_memory_reference"],
                    cognitionFrame: frame,
                    recordedAt: now
                )
            ],
            now: now
        )

        let visibleFields = [
            rows[0].relativeTime,
            rows[0].slowCognitionStatus,
            rows[0].slowCognitionDetail,
            rows[0].reviewStatus,
            rows[0].recoveryStatus,
            rows[0].riskSummary,
            rows[0].promptLayerSummary,
            rows[0].organSummary,
            rows[0].organDetail
        ].joined(separator: " ")

        XCTAssertFalse(visibleFields.contains("Help me plan"))
        XCTAssertFalse(visibleFields.contains("Assistant draft"))
        XCTAssertTrue(rows[0].organDetail.contains("redacted reason"))
    }

    func testRowsSummarizeCognitionFrameOrgans() {
        let now = Date(timeIntervalSince1970: 10_000)
        let frame = CognitionFrame(
            turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!,
            conversationId: UUID(uuidString: "00000000-0000-0000-0000-000000000502")!,
            assistantMessageId: UUID(uuidString: "00000000-0000-0000-0000-000000000503")!,
            records: [
                CognitionOrganRecord(
                    organ: .coordinator,
                    label: "turn_steward",
                    status: .used,
                    reason: "ordinary_chat"
                ),
                CognitionOrganRecord(
                    organ: .reviewer,
                    label: "provocation_judge",
                    status: .skipped,
                    reason: "provider_local"
                ),
                CognitionOrganRecord(
                    organ: .reviewer,
                    label: "reviewer",
                    status: .failed,
                    reason: "bad_json"
                )
            ],
            createdAt: now
        )
        let row = TurnCognitionInspectorFeedFormatting.rows(
            from: [
                snapshot(
                    suffix: "501",
                    promptLayers: ["anchor"],
                    slowCognitionAttached: false,
                    cognitionFrame: frame,
                    recordedAt: now
                )
            ],
            now: now
        )[0]

        XCTAssertEqual(row.organSummary, "3 organs: 1 used, 1 skipped, 1 failed")
        XCTAssertEqual(row.reviewStatus, "Review failed")
        XCTAssertTrue(row.organDetail.contains("turn steward used"))
        XCTAssertTrue(row.organDetail.contains("provocation judge skipped: provider local"))
        XCTAssertTrue(row.organDetail.contains("reviewer failed: bad json"))
    }

    func testRowsHandleMissingCognitionFrame() {
        let now = Date(timeIntervalSince1970: 10_000)
        let row = TurnCognitionInspectorFeedFormatting.rows(
            from: [
                snapshot(
                    suffix: "502",
                    promptLayers: ["anchor"],
                    slowCognitionAttached: false,
                    cognitionFrame: nil,
                    recordedAt: now
                )
            ],
            now: now
        )[0]

        XCTAssertEqual(row.organSummary, "No cognition frame")
        XCTAssertEqual(row.organDetail, "No organ trace")
    }

    private func makeTelemetry() -> GovernanceTelemetryStore {
        let suiteName = "TurnCognitionInspectorFeedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return GovernanceTelemetryStore(defaults: defaults)
    }

    private func snapshot(
        suffix: String,
        promptLayers: [String],
        slowCognitionAttached: Bool,
        slowCognitionArtifactId: UUID? = nil,
        slowCognitionEvidenceRefCount: Int = 0,
        reviewArtifactId: UUID? = nil,
        reviewRiskFlags: [String] = [],
        reviewConfidence: Double? = nil,
        conversationRecoveryReason: String? = nil,
        conversationRecoveryRebasedMessageCount: Int = 0,
        cognitionFrame: CognitionFrame? = nil,
        recordedAt: Date
    ) -> TurnCognitionSnapshot {
        TurnCognitionSnapshot(
            turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000\(suffix)")!,
            conversationId: UUID(uuidString: "00000000-0000-0000-0000-000000001\(suffix)")!,
            assistantMessageId: UUID(uuidString: "00000000-0000-0000-0000-000000002\(suffix)")!,
            promptLayers: promptLayers,
            slowCognitionAttached: slowCognitionAttached,
            slowCognitionArtifactId: slowCognitionArtifactId,
            slowCognitionEvidenceRefIds: [],
            slowCognitionEvidenceRefCount: slowCognitionEvidenceRefCount,
            reviewArtifactId: reviewArtifactId,
            reviewRiskFlags: reviewRiskFlags,
            reviewConfidence: reviewConfidence,
            conversationRecoveryReason: conversationRecoveryReason,
            conversationRecoveryOriginalNodeId: nil,
            conversationRecoveryRecoveredNodeId: nil,
            conversationRecoveryRebasedMessageCount: conversationRecoveryRebasedMessageCount,
            cognitionFrame: cognitionFrame,
            recordedAt: recordedAt
        )
    }
}
