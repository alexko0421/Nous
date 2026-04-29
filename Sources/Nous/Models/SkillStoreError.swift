import Foundation

enum SkillStoreError: LocalizedError, Equatable {
    case invalidPayloadVersion(Int)
    case emptyModes
    case priorityOutOfRange(Int)
    case emptyActionContent
    case payloadEncodingFailed
    case invalidSkillState(String)
    case invalidSkillIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayloadVersion(let version):
            return "Skill payloadVersion must be 1, got \(version)."
        case .emptyModes:
            return "Skill trigger modes must not be empty."
        case .priorityOutOfRange(let priority):
            return "Skill trigger priority must be between 0 and 100, got \(priority)."
        case .emptyActionContent:
            return "Skill action content must not be empty."
        case .payloadEncodingFailed:
            return "Skill payload could not be encoded as UTF-8 JSON."
        case .invalidSkillState(let state):
            return "Invalid skill state: \(state)."
        case .invalidSkillIdentifier(let id):
            return "Invalid skill id: \(id)."
        }
    }
}
