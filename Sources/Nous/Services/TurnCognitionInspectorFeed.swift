import Foundation

struct TurnCognitionInspectorFeed: Equatable {
    let summary: TurnCognitionTelemetrySummary
    let rows: [TurnCognitionInspectorRow]
}

struct TurnCognitionInspectorRow: Identifiable, Equatable {
    let id: UUID
    let turnId: UUID
    let recordedAt: Date
    let relativeTime: String
    let slowCognitionStatus: String
    let slowCognitionDetail: String
    let reviewStatus: String
    let recoveryStatus: String
    let riskSummary: String
    let promptLayerSummary: String
    let hasSlowSource: Bool
    let hasReviewRisk: Bool
    let hadConversationRecovery: Bool
}

enum TurnCognitionInspectorFeedFormatting {
    static func rows(from snapshots: [TurnCognitionSnapshot], now: Date = Date()) -> [TurnCognitionInspectorRow] {
        snapshots.map { snapshot in
            let evidenceCount = max(
                snapshot.slowCognitionEvidenceRefCount,
                snapshot.slowCognitionEvidenceRefIds.count
            )
            let hasSlowSource = snapshot.slowCognitionAttached &&
                snapshot.slowCognitionArtifactId != nil &&
                evidenceCount > 0
            let hasReviewRisk = !snapshot.reviewRiskFlags.isEmpty
            let hadConversationRecovery = snapshot.conversationRecoveryReason != nil ||
                snapshot.conversationRecoveryRebasedMessageCount > 0

            return TurnCognitionInspectorRow(
                id: snapshot.turnId,
                turnId: snapshot.turnId,
                recordedAt: snapshot.recordedAt,
                relativeTime: relative(snapshot.recordedAt, now: now),
                slowCognitionStatus: slowCognitionStatus(snapshot, hasSlowSource: hasSlowSource),
                slowCognitionDetail: slowCognitionDetail(snapshot, evidenceCount: evidenceCount),
                reviewStatus: reviewStatus(snapshot),
                recoveryStatus: recoveryStatus(snapshot),
                riskSummary: riskSummary(snapshot.reviewRiskFlags),
                promptLayerSummary: promptLayerSummary(snapshot.promptLayers.count),
                hasSlowSource: hasSlowSource,
                hasReviewRisk: hasReviewRisk,
                hadConversationRecovery: hadConversationRecovery
            )
        }
    }

    private static func slowCognitionStatus(
        _ snapshot: TurnCognitionSnapshot,
        hasSlowSource: Bool
    ) -> String {
        guard snapshot.slowCognitionAttached else { return "No slow signal" }
        return hasSlowSource ? "Sourced slow signal" : "Unsourced slow signal"
    }

    private static func slowCognitionDetail(
        _ snapshot: TurnCognitionSnapshot,
        evidenceCount: Int
    ) -> String {
        guard snapshot.slowCognitionAttached else { return "No slow_cognition layer" }
        guard snapshot.slowCognitionArtifactId != nil, evidenceCount > 0 else {
            return "Missing artifact or evidence refs"
        }
        return "\(evidenceCount) \(plural("evidence ref", evidenceCount))"
    }

    private static func reviewStatus(_ snapshot: TurnCognitionSnapshot) -> String {
        guard snapshot.reviewArtifactId != nil else { return "Not reviewed" }
        if !snapshot.reviewRiskFlags.isEmpty {
            let count = snapshot.reviewRiskFlags.count
            return "Reviewed: \(count) \(plural("risk flag", count))"
        }
        if let confidence = snapshot.reviewConfidence {
            return "Reviewed: clear, c \(String(format: "%.2f", confidence))"
        }
        return "Reviewed: clear"
    }

    private static func recoveryStatus(_ snapshot: TurnCognitionSnapshot) -> String {
        let rebasedCount = snapshot.conversationRecoveryRebasedMessageCount
        guard snapshot.conversationRecoveryReason != nil || rebasedCount > 0 else {
            return "No recovery"
        }

        let rebased = "\(rebasedCount) rebased \(plural("message", rebasedCount))"
        guard let reason = snapshot.conversationRecoveryReason else {
            return "Recovered: \(rebased)"
        }
        if rebasedCount > 0 {
            return "Recovered: \(display(reason)), \(rebased)"
        }
        return "Recovered: \(display(reason))"
    }

    private static func riskSummary(_ flags: [String]) -> String {
        guard !flags.isEmpty else { return "No risk flags" }
        return flags.map(display).joined(separator: ", ")
    }

    private static func promptLayerSummary(_ count: Int) -> String {
        "\(count) prompt \(plural("layer", count))"
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds == 0 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }

    private static func display(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
    }

    private static func plural(_ singular: String, _ count: Int) -> String {
        count == 1 ? singular : "\(singular)s"
    }
}

extension GovernanceTelemetryStore {
    func turnCognitionInspectorFeed(
        limit: Int = 8,
        now: Date = Date()
    ) -> TurnCognitionInspectorFeed {
        TurnCognitionInspectorFeed(
            summary: turnCognitionSummary,
            rows: TurnCognitionInspectorFeedFormatting.rows(
                from: recentTurnCognitionSnapshots(limit: limit),
                now: now
            )
        )
    }
}
