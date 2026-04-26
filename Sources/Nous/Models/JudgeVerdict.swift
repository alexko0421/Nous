// Sources/Nous/Models/JudgeVerdict.swift
import Foundation

enum UserState: String, Codable {
    case deciding
    case exploring
    case venting
}

enum JudgeFallbackReason: String, Codable {
    case ok
    case timeout
    case apiError = "api_error"
    case badJSON = "bad_json"
    case unknownEntryId = "unknown_entry_id"
    case providerLocal = "provider_local"
    case judgeUnavailable = "judge_unavailable"  // judge LLM factory returned nil (missing API key, etc.)
}

/// Review discriminator stamped onto a verdict by `ChatViewModel` before it is
/// persisted into `judge_events.verdictJSON`. Not emitted by the LLM judge —
/// derived deterministically from `shouldProvoke` and whether the cited entry
/// was a contradiction candidate this turn.
enum ProvocationKind: String, Codable, CaseIterable {
    case contradiction
    case spark
    case neutral
}

struct JudgeFeedbackLoop: Equatable {
    struct EntrySuppression: Equatable {
        let entryId: String
        let penalty: Double
        let reasonHints: [String]
    }

    struct KindAdjustment: Equatable {
        let kind: ProvocationKind
        let penalty: Double
        let reasonHints: [String]
    }

    let entrySuppressions: [EntrySuppression]
    let kindAdjustments: [KindAdjustment]
    let globalReasonHints: [String]
    let noteHints: [String]

    var isEmpty: Bool {
        entrySuppressions.isEmpty &&
        kindAdjustments.isEmpty &&
        globalReasonHints.isEmpty &&
        noteHints.isEmpty
    }
}

struct MonitorSummary: Codable, Equatable {
    let state: String
    let confidenceEvidenceGap: String
    let positiveEventShare: Bool?

    init(state: String, confidenceEvidenceGap: String, positiveEventShare: Bool? = nil) {
        self.state = state
        self.confidenceEvidenceGap = confidenceEvidenceGap
        self.positiveEventShare = positiveEventShare
    }

    enum CodingKeys: String, CodingKey {
        case state
        case confidenceEvidenceGap = "confidence_evidence_gap"
        case positiveEventShare = "positive_event_share"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.state = try c.decode(String.self, forKey: .state)
        self.confidenceEvidenceGap = try c.decode(String.self, forKey: .confidenceEvidenceGap)
        self.positiveEventShare = try c.decodeIfPresent(Bool.self, forKey: .positiveEventShare)
    }
}

struct JudgeVerdict: Codable, Equatable {
    let tensionExists: Bool
    let userState: UserState
    let monitorSummary: MonitorSummary?
    let shouldProvoke: Bool
    let entryId: String?
    let reason: String
    let inferredMode: ChatMode
    var provocationKind: ProvocationKind

    init(
        tensionExists: Bool,
        userState: UserState,
        monitorSummary: MonitorSummary? = nil,
        shouldProvoke: Bool,
        entryId: String?,
        reason: String,
        inferredMode: ChatMode,
        provocationKind: ProvocationKind = .neutral
    ) {
        self.tensionExists = tensionExists
        self.userState = userState
        self.monitorSummary = monitorSummary
        self.shouldProvoke = shouldProvoke
        self.entryId = entryId
        self.reason = reason
        self.inferredMode = inferredMode
        self.provocationKind = provocationKind
    }

    enum CodingKeys: String, CodingKey {
        case tensionExists = "tension_exists"
        case userState = "user_state"
        case monitorSummary = "monitor_summary"
        case shouldProvoke = "should_provoke"
        case entryId = "entry_id"
        case reason
        case inferredMode = "inferred_mode"
        case provocationKind = "provocation_kind"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tensionExists = try c.decode(Bool.self, forKey: .tensionExists)
        self.userState = try c.decode(UserState.self, forKey: .userState)
        self.monitorSummary = try c.decodeIfPresent(MonitorSummary.self, forKey: .monitorSummary)
        self.shouldProvoke = try c.decode(Bool.self, forKey: .shouldProvoke)
        self.entryId = try c.decodeIfPresent(String.self, forKey: .entryId)
        self.reason = try c.decode(String.self, forKey: .reason)
        self.inferredMode = try c.decode(ChatMode.self, forKey: .inferredMode)
        self.provocationKind = try c.decodeIfPresent(ProvocationKind.self, forKey: .provocationKind) ?? .neutral
    }
}
