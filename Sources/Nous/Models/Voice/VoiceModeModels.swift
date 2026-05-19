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
    case settings

    var actionTitle: String {
        switch self {
        case .chat: return "Opening Chat"
        case .notes: return "Opening Notes"
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

enum VoiceOutputVoice: String, CaseIterable, Identifiable {
    case cedar
    case marin
    case verse
    case coral
    case sage
    case shimmer
    case alloy
    case ash
    case ballad
    case echo

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }
}

enum RealtimeVoiceModel: String, CaseIterable, Identifiable {
    case realtime2 = "gpt-realtime-2"
    case realtimeMini = "gpt-realtime-mini"

    var id: String { rawValue }
}

enum RealtimeReasoningEffort: String, CaseIterable, Identifiable {
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }
}

enum VoiceLanguage: String, CaseIterable, Identifiable {
    case automatic
    case cantonese
    case mandarin
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Auto"
        case .cantonese: return "粵語"
        case .mandarin: return "普通話"
        case .english: return "English"
        }
    }

    var transcriptionLanguageCode: String? {
        switch self {
        case .automatic: return nil
        case .cantonese, .mandarin: return "zh"
        case .english: return "en"
        }
    }

    var realtimeInstruction: String {
        switch self {
        case .automatic:
            return "Mirror the user's language and dialect. Speak naturally, like a present thinking partner. If Alex speaks Cantonese, respond in colloquial Cantonese with Hong Kong rhythm, light particles, small pauses, and real energy shifts; do not flatten into Mandarin or formal narration."
        case .cantonese:
            return "Use colloquial Cantonese by default. Preserve Cantonese wording and particles. Keep it warm and conversational with Hong Kong rhythm, small pauses, and subtle emotional movement; do not silently convert Cantonese into Mandarin."
        case .mandarin:
            return "Use standard Mandarin Chinese by default, with Mainland 普通话 wording and phrasing. Keep it natural, warm, and conversational. Do not respond in Cantonese unless Alex switches language."
        case .english:
            return "Use English by default in a natural, warm, conversational voice unless Alex explicitly asks for another language."
        }
    }

    var previewText: String {
        switch self {
        case .automatic:
            return "Hi Alex, I am Nous. I can listen, think with you, and help you turn scattered thoughts into memory."
        case .cantonese:
            return "Alex，我係 Nous。我會聽住你講，幫你整理諗法，唔會將你嘅廣東話硬轉做普通話。"
        case .mandarin:
            return "Alex，我是 Nous。我会听你说，帮你整理想法，把零散的内容变成记忆。"
        case .english:
            return "Hi Alex, I am Nous. I can listen, think with you, and help you turn scattered thoughts into memory."
        }
    }

    var previewInstructions: String {
        switch self {
        case .automatic:
            return "Sound warm, present, and conversational. Match the language of the text. Avoid announcer or assistant-script delivery."
        case .cantonese:
            return "Speak natural Hong Kong Cantonese with a warm, present tone, small pauses, and real energy shifts. Keep it conversational, not formal, flat, or over-polished."
        case .mandarin:
            return "Speak natural standard Mandarin Chinese with Mainland 普通话 pronunciation and wording. Keep it warm, present, and conversational."
        case .english:
            return "Speak in warm, present English. Keep it conversational, not like an announcement."
        }
    }
}

struct RealtimeVoiceConfiguration: Equatable {
    var model: RealtimeVoiceModel
    var voice: VoiceOutputVoice
    var language: VoiceLanguage
    var reasoningEffort: RealtimeReasoningEffort?

    init(
        model: RealtimeVoiceModel = .realtime2,
        voice: VoiceOutputVoice,
        language: VoiceLanguage,
        reasoningEffort: RealtimeReasoningEffort? = .medium
    ) {
        self.model = model
        self.voice = voice
        self.language = language
        self.reasoningEffort = reasoningEffort
    }

    static let `default` = RealtimeVoiceConfiguration(
        model: .realtime2,
        voice: .cedar,
        language: .automatic,
        reasoningEffort: .medium
    )
}

struct VoiceAppSnapshot: Equatable {
    var currentTab: VoiceNavigationTarget
    var settingsSection: VoiceSettingsSection?
    var composerText: String
    var sidebarVisible: Bool
    var scratchpadVisible: Bool
    var scratchpadMarkdown: String
    var activeConversationTitle: String?
    var rightPanelMode: String?
    var youtubeURLText: String?
    var activeSourceTitle: String?
    var activeSourceTimeRange: String?
    var activeSourceSummaryTitle: String?
    var activeSourceEvidenceLevel: String?

    init(
        currentTab: VoiceNavigationTarget,
        settingsSection: VoiceSettingsSection?,
        composerText: String,
        sidebarVisible: Bool,
        scratchpadVisible: Bool,
        scratchpadMarkdown: String = "",
        activeConversationTitle: String?,
        rightPanelMode: String? = nil,
        youtubeURLText: String? = nil,
        activeSourceTitle: String? = nil,
        activeSourceTimeRange: String? = nil,
        activeSourceSummaryTitle: String? = nil,
        activeSourceEvidenceLevel: String? = nil
    ) {
        self.currentTab = currentTab
        self.settingsSection = settingsSection
        self.composerText = composerText
        self.sidebarVisible = sidebarVisible
        self.scratchpadVisible = scratchpadVisible
        self.scratchpadMarkdown = scratchpadMarkdown
        self.activeConversationTitle = activeConversationTitle
        self.rightPanelMode = rightPanelMode
        self.youtubeURLText = youtubeURLText
        self.activeSourceTitle = activeSourceTitle
        self.activeSourceTimeRange = activeSourceTimeRange
        self.activeSourceSummaryTitle = activeSourceSummaryTitle
        self.activeSourceEvidenceLevel = activeSourceEvidenceLevel
    }

    func jsonString() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "current_tab": currentTab.rawValue,
                "settings_section": Self.stringOrNull(settingsSection?.rawValue),
                "composer_text": composerText,
                "sidebar_visible": sidebarVisible,
                "scratchpad_visible": scratchpadVisible,
                "scratchpad_markdown": scratchpadMarkdown,
                "active_conversation_title": Self.stringOrNull(activeConversationTitle),
                "right_panel_mode": Self.stringOrNull(rightPanelMode),
                "youtube_url_text": Self.stringOrNull(youtubeURLText),
                "active_source_title": Self.stringOrNull(activeSourceTitle),
                "active_source_time_range": Self.stringOrNull(activeSourceTimeRange),
                "active_source_summary_title": Self.stringOrNull(activeSourceSummaryTitle),
                "active_source_evidence_level": Self.stringOrNull(activeSourceEvidenceLevel)
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
        sidebarVisible: false,
        scratchpadVisible: false,
        scratchpadMarkdown: "",
        activeConversationTitle: nil
    )
}

struct VoiceToolCall: Equatable {
    let name: String
    let arguments: String
}

struct VoiceSummaryPreview: Equatable {
    var title: String
    var markdown: String
}

struct VoiceYouTubeSummaryResult: Equatable {
    var succeeded: Bool
    var status: String
    var output: String

    static let missingURL = VoiceYouTubeSummaryResult(
        succeeded: false,
        status: "Paste or enter a YouTube URL first.",
        output: "Paste or enter a YouTube URL first."
    )
}

struct VoiceSourceContextResult: Equatable {
    var hasContext: Bool
    var status: String
    var output: String

    init(context: SourceDiscussionContext) {
        hasContext = true
        status = "Source context ready"
        output = Self.output(for: context)
    }

    static let noActiveSourceContext = VoiceSourceContextResult(
        hasContext: false,
        status: "Click a source section first",
        output: "No source section is selected. Ask Alex to click a YouTube summary section first."
    )

    private init(hasContext: Bool, status: String, output: String) {
        self.hasContext = hasContext
        self.status = status
        self.output = output
    }

    private static func output(for context: SourceDiscussionContext) -> String {
        let excerptLabel = context.isQuoteLevelReliable ? "Transcript excerpt" : "Analysis excerpt"
        let sourceURLLine = context.sourceURL.map { "\nSource URL: \($0)" } ?? ""

        return """
        SOURCE MATERIAL
        Title: \(context.title)
        Section: \(context.summaryTitle) (\(context.timeRangeLabel))
        Evidence: \(context.evidenceLabel)\(sourceURLLine)

        Summary:
        \(context.summary)

        \(excerptLabel):
        \(context.transcriptExcerpt)
        """
    }
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
    var openScratchPadForWriting: () -> Void
    var replaceScratchPadMarkdown: (String) -> Void
    var appendScratchPadMarkdown: (String) -> Void
    var setComposerText: (String) -> Void
    var appendComposerText: (String) -> Void
    var clearComposer: () -> Void
    var startNewChat: () -> Void
    var createNote: (String, String) -> Void
    var summarizeYouTubeVideo: (String?) async -> VoiceYouTubeSummaryResult
    var getActiveSourceContext: () -> VoiceSourceContextResult
    var setAppearanceMode: (VoiceAppearanceMode) -> Void
    var openSettingsSection: (VoiceSettingsSection) -> Void
    var appSnapshot: () -> VoiceAppSnapshot

    init(
        navigate: @escaping (VoiceNavigationTarget) -> Void,
        setSidebarVisible: @escaping (Bool) -> Void,
        setScratchPadVisible: @escaping (Bool) -> Void,
        openScratchPadForWriting: @escaping () -> Void = {},
        replaceScratchPadMarkdown: @escaping (String) -> Void = { _ in },
        appendScratchPadMarkdown: @escaping (String) -> Void = { _ in },
        setComposerText: @escaping (String) -> Void,
        appendComposerText: @escaping (String) -> Void,
        clearComposer: @escaping () -> Void,
        startNewChat: @escaping () -> Void,
        createNote: @escaping (String, String) -> Void,
        summarizeYouTubeVideo: @escaping (String?) async -> VoiceYouTubeSummaryResult = { _ in .missingURL },
        getActiveSourceContext: @escaping () -> VoiceSourceContextResult = { .noActiveSourceContext },
        setAppearanceMode: @escaping (VoiceAppearanceMode) -> Void = { _ in },
        openSettingsSection: @escaping (VoiceSettingsSection) -> Void = { _ in },
        appSnapshot: @escaping () -> VoiceAppSnapshot = { .empty }
    ) {
        self.navigate = navigate
        self.setSidebarVisible = setSidebarVisible
        self.setScratchPadVisible = setScratchPadVisible
        self.openScratchPadForWriting = openScratchPadForWriting
        self.replaceScratchPadMarkdown = replaceScratchPadMarkdown
        self.appendScratchPadMarkdown = appendScratchPadMarkdown
        self.setComposerText = setComposerText
        self.appendComposerText = appendComposerText
        self.clearComposer = clearComposer
        self.startNewChat = startNewChat
        self.createNote = createNote
        self.summarizeYouTubeVideo = summarizeYouTubeVideo
        self.getActiveSourceContext = getActiveSourceContext
        self.setAppearanceMode = setAppearanceMode
        self.openSettingsSection = openSettingsSection
        self.appSnapshot = appSnapshot
    }

    static let empty = VoiceActionHandlers(
        navigate: { _ in },
        setSidebarVisible: { _ in },
        setScratchPadVisible: { _ in },
        openScratchPadForWriting: {},
        replaceScratchPadMarkdown: { _ in },
        appendScratchPadMarkdown: { _ in },
        setComposerText: { _ in },
        appendComposerText: { _ in },
        clearComposer: {},
        startNewChat: {},
        createNote: { _, _ in },
        summarizeYouTubeVideo: { _ in .missingURL },
        getActiveSourceContext: { .noActiveSourceContext },
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

enum VoiceCapsuleVisibilityPolicy {
    static func shouldShowCapsule(
        isVoiceActive: Bool,
        status: VoiceModeStatus,
        hasPendingAction: Bool,
        hasSummaryPreview: Bool,
        isChatSurface: Bool = false
    ) -> Bool {
        if isChatSurface && !hasPendingAction && !hasSummaryPreview {
            switch status {
            case .error:
                break
            case .idle, .listening, .thinking, .action, .needsConfirmation:
                return false
            }
        }

        return isVoiceActive || status.shouldDisplayPill || hasPendingAction || hasSummaryPreview
    }
}
