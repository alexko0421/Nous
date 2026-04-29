import Foundation

struct VoiceTranscriptLine: Identifiable, Equatable, Codable {
    enum Role: String, Codable, Equatable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    var isFinal: Bool
    let createdAt: Date

    init(id: UUID = UUID(), role: Role, text: String, isFinal: Bool, createdAt: Date) {
        self.id = id
        self.role = role
        self.text = text
        self.isFinal = isFinal
        self.createdAt = createdAt
    }

    static func appendDelta(
        _ delta: String,
        role: Role,
        into lines: inout [VoiceTranscriptLine],
        now: Date = Date()
    ) {
        if var last = lines.last, last.role == role, last.isFinal == false {
            last.text += delta
            lines[lines.count - 1] = last
            return
        }
        lines.append(VoiceTranscriptLine(role: role, text: delta, isFinal: false, createdAt: now))
    }

    static func finalize(
        text: String,
        role: Role,
        into lines: inout [VoiceTranscriptLine],
        now: Date = Date()
    ) {
        if var last = lines.last, last.role == role, last.isFinal == false {
            last.text = text
            last.isFinal = true
            lines[lines.count - 1] = last
            return
        }
        lines.append(VoiceTranscriptLine(role: role, text: text, isFinal: true, createdAt: now))
    }

    static func bargeInSealsLatestAssistant(into lines: inout [VoiceTranscriptLine]) {
        guard var last = lines.last, last.role == .assistant, last.isFinal == false else { return }
        last.isFinal = true
        lines[lines.count - 1] = last
    }
}
