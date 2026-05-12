import Foundation

enum SkillStoreError: LocalizedError, Equatable {
    case invalidPayloadVersion(Int)
    case emptyModes
    case emptyCues
    case priorityOutOfRange(Int)
    case emptyActionContent
    case payloadEncodingFailed
    case invalidSkillState(String)
    case invalidSkillIdentifier(String)
    case nodeStoreMismatch

    var errorDescription: String? {
        switch self {
        case .invalidPayloadVersion(let version):
            return "Skill payloadVersion must be 1...2, got \(version)."
        case .emptyModes:
            return "Skill trigger modes must not be empty."
        case .emptyCues:
            return "Skill analysis gate cues must not be empty."
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
        case .nodeStoreMismatch:
            return "Skill activation must use the same NodeStore transaction."
        }
    }
}

enum SkillPayloadValidator {
    static func validate(_ payload: SkillPayload) throws {
        guard (1...2).contains(payload.payloadVersion) else {
            throw SkillStoreError.invalidPayloadVersion(payload.payloadVersion)
        }

        switch payload.trigger.kind {
        case .analysisGate:
            let nonEmptyCues = payload.trigger.cues.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !nonEmptyCues.isEmpty else {
                throw SkillStoreError.emptyCues
            }
        case .always:
            break
        case .mode:
            guard !payload.trigger.modes.isEmpty else {
                throw SkillStoreError.emptyModes
            }
        }

        guard 0...100 ~= payload.trigger.priority else {
            throw SkillStoreError.priorityOutOfRange(payload.trigger.priority)
        }
        guard !payload.action.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillStoreError.emptyActionContent
        }
    }
}
