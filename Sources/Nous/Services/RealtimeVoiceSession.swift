import Foundation

enum RealtimeVoiceEvent: Equatable {
    case sessionReady
    case toolCall(VoiceToolCall, callId: String)
    case responseDone
    case error(String)
}

enum RealtimeVoiceEventParser {
    static func parse(_ raw: String) -> RealtimeVoiceEvent? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "session.created", "session.updated":
            return .sessionReady
        case "response.function_call_arguments.done":
            guard let name = json["name"] as? String,
                  let arguments = json["arguments"] as? String,
                  let callId = json["call_id"] as? String else {
                return .error("Invalid tool call")
            }
            return .toolCall(VoiceToolCall(name: name, arguments: arguments), callId: callId)
        case "response.done":
            return parseResponseDone(json)
        case "error":
            let error = json["error"] as? [String: Any]
            return .error(error?["message"] as? String ?? "Realtime error")
        default:
            return nil
        }
    }

    private static func parseResponseDone(_ json: [String: Any]) -> RealtimeVoiceEvent {
        let response = json["response"] as? [String: Any]
        guard let status = response?["status"] as? String,
              status != "completed" else {
            return .responseDone
        }

        let statusDetails = response?["status_details"] as? [String: Any]
        let error = statusDetails?["error"] as? [String: Any]
        let message = error?["message"] as? String

        if let message, !message.isEmpty {
            return .error("Realtime response \(status): \(message)")
        }
        return .error("Realtime response \(status)")
    }
}

final class RealtimeVoiceSession {
    static let defaultModel = "gpt-realtime"

    static func makeRequest(apiKey: String, model: String = defaultModel) -> URLRequest {
        var components = URLComponents(string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func makeSessionUpdateEvent(model: String = defaultModel) throws -> Data {
        let body: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "instructions": voiceInstructions,
                "output_modalities": ["text"],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "turn_detection": [
                            "type": "semantic_vad"
                        ]
                    ]
                ],
                "tools": voiceToolDeclarations,
                "tool_choice": "auto"
            ]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func makeAudioAppendEvent(base64Audio: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ])
    }

    static func makeFunctionOutputEvent(callId: String, output: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": output
            ]
        ], options: [.sortedKeys])
    }

    static func makeResponseCreateEvent() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "response.create",
            "response": [
                "output_modalities": ["text"]
            ]
        ])
    }

    private static let voiceInstructions = """
    You are the voice control layer for Nous. Call tools only for explicit user intent. \
    Use direct tools for navigation, scratchpad/sidebar visibility, and composer drafting. \
    Use propose_* tools for sending messages or creating notes. Never claim you clicked UI.
    """

    private static let voiceToolDeclarations: [[String: Any]] = [
        functionTool(
            name: "navigate_to_tab",
            description: "Navigate to a main Nous tab.",
            properties: [
                "tab": ["type": "string", "enum": ["chat", "notes", "galaxy", "settings"]]
            ],
            required: ["tab"]
        ),
        functionTool(
            name: "set_sidebar_visibility",
            description: "Show or hide the left sidebar.",
            properties: ["visible": ["type": "boolean"]],
            required: ["visible"]
        ),
        functionTool(
            name: "set_scratchpad_visibility",
            description: "Show or hide the scratchpad panel.",
            properties: ["visible": ["type": "boolean"]],
            required: ["visible"]
        ),
        functionTool(
            name: "set_composer_text",
            description: "Replace the current composer draft.",
            properties: ["text": ["type": "string"]],
            required: ["text"]
        ),
        functionTool(
            name: "append_composer_text",
            description: "Append text to the current composer draft.",
            properties: ["text": ["type": "string"]],
            required: ["text"]
        ),
        functionTool(
            name: "clear_composer",
            description: "Clear the current composer draft.",
            properties: [:],
            required: []
        ),
        functionTool(
            name: "start_new_chat",
            description: "Start a blank chat state.",
            properties: [:],
            required: []
        ),
        functionTool(
            name: "propose_send_message",
            description: "Propose sending a chat message. The app will ask for confirmation.",
            properties: ["text": ["type": "string"]],
            required: ["text"]
        ),
        functionTool(
            name: "propose_note",
            description: "Propose creating a note. The app will ask for confirmation.",
            properties: ["title": ["type": "string"], "body": ["type": "string"]],
            required: ["title", "body"]
        ),
        functionTool(
            name: "confirm_pending_action",
            description: "Confirm the pending send or create action.",
            properties: [:],
            required: []
        ),
        functionTool(
            name: "cancel_pending_action",
            description: "Cancel the pending send or create action.",
            properties: [:],
            required: []
        )
    ]

    private static func functionTool(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
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
