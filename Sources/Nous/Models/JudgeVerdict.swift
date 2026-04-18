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

struct JudgeVerdict: Codable, Equatable {
    let tensionExists: Bool
    let userState: UserState
    let shouldProvoke: Bool
    let entryId: String?
    let reason: String
    let inferredMode: ChatMode

    enum CodingKeys: String, CodingKey {
        case tensionExists = "tension_exists"
        case userState = "user_state"
        case shouldProvoke = "should_provoke"
        case entryId = "entry_id"
        case reason
        case inferredMode = "inferred_mode"
    }

    init(tensionExists: Bool, userState: UserState, shouldProvoke: Bool,
         entryId: String?, reason: String, inferredMode: ChatMode = .companion) {
        self.tensionExists = tensionExists
        self.userState = userState
        self.shouldProvoke = shouldProvoke
        self.entryId = entryId
        self.reason = reason
        self.inferredMode = inferredMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tensionExists = try container.decode(Bool.self, forKey: .tensionExists)
        userState = try container.decode(UserState.self, forKey: .userState)
        shouldProvoke = try container.decode(Bool.self, forKey: .shouldProvoke)
        entryId = try container.decodeIfPresent(String.self, forKey: .entryId)
        reason = try container.decode(String.self, forKey: .reason)
        inferredMode = try container.decodeIfPresent(ChatMode.self, forKey: .inferredMode) ?? .companion
    }
}
