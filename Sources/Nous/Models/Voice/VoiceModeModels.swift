import Foundation

enum VoiceModeStatus: Equatable {
    case idle
    case listening
    case thinking
    case action(String)
    case needsConfirmation(String)
    case error(String)

    var displayText: String {
        switch self {
        case .idle: return "Voice"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .action(let text): return text
        case .needsConfirmation(let text): return text
        case .error(let text): return text
        }
    }
}

enum VoiceNavigationTarget: String, CaseIterable, Equatable {
    case chat
    case notes
    case galaxy
    case settings

    var actionTitle: String {
        switch self {
        case .chat: return "Opening Chat"
        case .notes: return "Opening Notes"
        case .galaxy: return "Opening Galaxy"
        case .settings: return "Opening Settings"
        }
    }
}

struct VoiceToolCall: Equatable {
    let name: String
    let arguments: String
}

enum VoicePendingAction: Equatable {
    case sendMessage(text: String)
    case createNote(title: String, body: String)
}

enum VoiceToolError: Error, Equatable {
    case unknownTool(String)
    case invalidJSON
    case invalidArgument(String)
    case missingArgument(String)
    case pendingActionAlreadyExists
}

struct VoiceActionHandlers {
    var navigate: (VoiceNavigationTarget) -> Void
    var setSidebarVisible: (Bool) -> Void
    var setScratchPadVisible: (Bool) -> Void
    var setComposerText: (String) -> Void
    var appendComposerText: (String) -> Void
    var clearComposer: () -> Void
    var startNewChat: () -> Void
    var sendMessage: (String) -> Void
    var createNote: (String, String) -> Void

    static let empty = VoiceActionHandlers(
        navigate: { _ in },
        setSidebarVisible: { _ in },
        setScratchPadVisible: { _ in },
        setComposerText: { _ in },
        appendComposerText: { _ in },
        clearComposer: {},
        startNewChat: {},
        sendMessage: { _ in },
        createNote: { _, _ in }
    )
}
