import Foundation

enum VoiceModeStatus: Equatable {
    case idle
    case listening
    case thinking
    case action(String)
    case needsConfirmation(String)
    case error(String)

    var shouldDisplayPill: Bool {
        switch self {
        case .idle:
            return false
        case .listening, .thinking, .action, .needsConfirmation, .error:
            return true
        }
    }

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

enum VoiceModeToggleAction: Equatable {
    case stop
    case start(apiKey: String)
    case unavailable(String)
}

enum VoiceModeTogglePolicy {
    static func action(
        isActive: Bool,
        isVoiceModeAvailable: Bool,
        apiKey: String
    ) -> VoiceModeToggleAction {
        if isActive {
            return .stop
        }

        guard isVoiceModeAvailable else {
            return .unavailable("Add OpenAI API key")
        }

        return .start(apiKey: apiKey)
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

enum VoiceAppearanceMode: String, CaseIterable, Equatable {
    case light
    case dark
    case system

    var actionTitle: String {
        switch self {
        case .light: return "Light Mode"
        case .dark: return "Dark Mode"
        case .system: return "Auto Appearance"
        }
    }
}

enum VoiceSettingsSection: String, CaseIterable, Equatable {
    case profile
    case general
    case models
    case memory

    var actionTitle: String {
        switch self {
        case .profile: return "Opening Profile Settings"
        case .general: return "Opening General Settings"
        case .models: return "Opening Model Settings"
        case .memory: return "Opening Memory Settings"
        }
    }
}

enum VoiceActionRisk: Equatable {
    case direct
    case confirmationRequired
    case readOnly
}

struct VoiceAppSnapshot: Equatable {
    var currentTab: VoiceNavigationTarget
    var settingsSection: VoiceSettingsSection?
    var composerText: String
    var selectedProjectName: String?
    var sidebarVisible: Bool
    var scratchpadVisible: Bool
    var activeConversationTitle: String?

    func jsonString() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "current_tab": currentTab.rawValue,
                "settings_section": Self.stringOrNull(settingsSection?.rawValue),
                "composer_text": composerText,
                "selected_project_name": Self.stringOrNull(selectedProjectName),
                "sidebar_visible": sidebarVisible,
                "scratchpad_visible": scratchpadVisible,
                "active_conversation_title": Self.stringOrNull(activeConversationTitle)
            ],
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func stringOrNull(_ value: String?) -> Any {
        value ?? NSNull()
    }

    static let empty = VoiceAppSnapshot(
        currentTab: .chat,
        settingsSection: nil,
        composerText: "",
        selectedProjectName: nil,
        sidebarVisible: false,
        scratchpadVisible: false,
        activeConversationTitle: nil
    )
}

struct VoiceToolCall: Equatable {
    let name: String
    let arguments: String
}

enum VoicePendingAction: Equatable {
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
    var createNote: (String, String) -> Void
    var setAppearanceMode: (VoiceAppearanceMode) -> Void
    var openSettingsSection: (VoiceSettingsSection) -> Void
    var appSnapshot: () -> VoiceAppSnapshot

    init(
        navigate: @escaping (VoiceNavigationTarget) -> Void,
        setSidebarVisible: @escaping (Bool) -> Void,
        setScratchPadVisible: @escaping (Bool) -> Void,
        setComposerText: @escaping (String) -> Void,
        appendComposerText: @escaping (String) -> Void,
        clearComposer: @escaping () -> Void,
        startNewChat: @escaping () -> Void,
        createNote: @escaping (String, String) -> Void,
        setAppearanceMode: @escaping (VoiceAppearanceMode) -> Void = { _ in },
        openSettingsSection: @escaping (VoiceSettingsSection) -> Void = { _ in },
        appSnapshot: @escaping () -> VoiceAppSnapshot = { .empty }
    ) {
        self.navigate = navigate
        self.setSidebarVisible = setSidebarVisible
        self.setScratchPadVisible = setScratchPadVisible
        self.setComposerText = setComposerText
        self.appendComposerText = appendComposerText
        self.clearComposer = clearComposer
        self.startNewChat = startNewChat
        self.createNote = createNote
        self.setAppearanceMode = setAppearanceMode
        self.openSettingsSection = openSettingsSection
        self.appSnapshot = appSnapshot
    }

    static let empty = VoiceActionHandlers(
        navigate: { _ in },
        setSidebarVisible: { _ in },
        setScratchPadVisible: { _ in },
        setComposerText: { _ in },
        appendComposerText: { _ in },
        clearComposer: {},
        startNewChat: {},
        createNote: { _, _ in },
        setAppearanceMode: { _ in },
        openSettingsSection: { _ in },
        appSnapshot: { .empty }
    )
}

enum VoiceCapsuleSurface: Equatable {
    case none
    case inWindow
    case notch
}

enum VoiceCapsuleSurfacePolicy {
    static func nextSurface(
        isVoiceActive: Bool,
        hasPendingAction: Bool,
        currentSurface: VoiceCapsuleSurface,
        isMainWorkspaceActive: Bool,
        hasNotchScreen: Bool
    ) -> VoiceCapsuleSurface {
        if hasPendingAction {
            return currentSurface
        }

        guard isVoiceActive else {
            return .none
        }

        if isMainWorkspaceActive {
            return .inWindow
        }

        return hasNotchScreen ? .notch : .inWindow
    }
}
