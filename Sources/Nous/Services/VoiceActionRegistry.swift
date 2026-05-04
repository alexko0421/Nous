import Foundation

enum VoiceActionRegistry {
    struct Tool {
        let name: String
        let description: String
        let properties: [String: Any]
        let required: [String]
        let risk: VoiceActionRisk

        var declaration: [String: Any] {
            [
                "type": "function",
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                    "additionalProperties": false
                ]
            ]
        }
    }

    static func declarations(includeMemoryTools: Bool) -> [[String: Any]] {
        tools(includeMemoryTools: includeMemoryTools).map(\.declaration)
    }

    static func risk(for toolName: String) -> VoiceActionRisk? {
        allToolsByName[toolName]?.risk
    }

    static func tools(includeMemoryTools: Bool) -> [Tool] {
        includeMemoryTools ? baseTools + memoryTools : baseTools
    }

    private static let allToolsByName: [String: Tool] = Dictionary(
        uniqueKeysWithValues: (baseTools + memoryTools).map { ($0.name, $0) }
    )

    private static let baseTools: [Tool] = [
        Tool(
            name: "get_app_state",
            description: "Get a short read-only snapshot of current Nous app state.",
            properties: [:],
            required: [],
            risk: .readOnly
        ),
        Tool(
            name: "navigate_to_tab",
            description: "Navigate to a main Nous tab.",
            properties: [
                "tab": ["type": "string", "enum": ["chat", "notes", "galaxy", "settings"]]
            ],
            required: ["tab"],
            risk: .direct
        ),
        Tool(
            name: "set_sidebar_visibility",
            description: "Show or hide the left sidebar.",
            properties: ["visible": ["type": "boolean"]],
            required: ["visible"],
            risk: .direct
        ),
        Tool(
            name: "set_scratchpad_visibility",
            description: "Show or hide the scratchpad panel.",
            properties: ["visible": ["type": "boolean"]],
            required: ["visible"],
            risk: .direct
        ),
        Tool(
            name: "set_appearance_mode",
            description: "Set the Nous appearance directly. Use for light mode, dark mode, or automatic system appearance requests.",
            properties: [
                "mode": ["type": "string", "enum": ["light", "dark", "system"]]
            ],
            required: ["mode"],
            risk: .direct
        ),
        Tool(
            name: "open_settings_section",
            description: "Open a specific Settings section without ending Voice Mode.",
            properties: [
                "section": ["type": "string", "enum": ["profile", "general", "models", "memory"]]
            ],
            required: ["section"],
            risk: .direct
        ),
        Tool(
            name: "set_composer_text",
            description: "Replace the current composer draft.",
            properties: ["text": ["type": "string"]],
            required: ["text"],
            risk: .direct
        ),
        Tool(
            name: "append_composer_text",
            description: "Append text to the current composer draft.",
            properties: ["text": ["type": "string"]],
            required: ["text"],
            risk: .direct
        ),
        Tool(
            name: "clear_composer",
            description: "Clear the current composer draft.",
            properties: [:],
            required: [],
            risk: .direct
        ),
        Tool(
            name: "start_new_chat",
            description: "Start a blank chat state.",
            properties: [:],
            required: [],
            risk: .direct
        ),
        Tool(
            name: "show_summary_preview",
            description: "Show a transient markdown summary paper below the voice capsule. Use when Alex asks to summarize, recap, or organize the current spoken thought.",
            properties: [
                "title": ["type": "string"],
                "markdown": ["type": "string"]
            ],
            required: ["title", "markdown"],
            risk: .direct
        ),
        Tool(
            name: "dismiss_summary_preview",
            description: "Dismiss the visible voice summary paper.",
            properties: [:],
            required: [],
            risk: .direct
        ),
        Tool(
            name: "propose_note",
            description: "Propose creating a note. The app will ask for confirmation.",
            properties: ["title": ["type": "string"], "body": ["type": "string"]],
            required: ["title", "body"],
            risk: .confirmationRequired
        ),
        Tool(
            name: "confirm_pending_action",
            description: "Confirm the pending send or create action.",
            properties: [:],
            required: [],
            risk: .confirmationRequired
        ),
        Tool(
            name: "cancel_pending_action",
            description: "Cancel the pending send or create action.",
            properties: [:],
            required: [],
            risk: .confirmationRequired
        )
    ]

    private static let memoryTools: [Tool] = [
        Tool(
            name: "search_memory",
            description: "Search Nous memory for short read-only context.",
            properties: [
                "query": ["type": "string"],
                "limit": ["type": "integer"]
            ],
            required: ["query"],
            risk: .readOnly
        ),
        Tool(
            name: "recall_recent_conversations",
            description: "Recall short read-only summaries from recent conversations.",
            properties: ["limit": ["type": "integer"]],
            required: [],
            risk: .readOnly
        )
    ]
}
