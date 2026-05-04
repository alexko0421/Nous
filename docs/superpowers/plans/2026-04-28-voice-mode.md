# Voice Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS Voice Mode that lets Alex speak to Nous, execute safe app-owned actions like opening Galaxy, and confirm persistent actions before they run.

**Architecture:** Voice Mode is a separate control loop from normal chat. `RealtimeVoiceSession` owns OpenAI Realtime WebSocket and microphone streaming; `VoiceCommandController` owns tool validation, action state, and pending confirmations on the main actor; `ContentView` and `ChatArea` inject app-owned closures for navigation, composer drafting, and confirmed sends. The model never clicks UI or mutates data directly.

**Tech Stack:** SwiftUI, Observation, AVFoundation, URLSessionWebSocketTask, OpenAI Realtime WebSocket (`gpt-realtime`), XCTest, existing `NodeStore` / `VectorStore` / `EmbeddingService`.

---

## References Checked

- Design spec: `docs/superpowers/specs/2026-04-28-voice-mode-design.md`
- OpenAI WebSocket guide: `https://developers.openai.com/api/docs/guides/realtime-websocket`
- OpenAI Realtime conversations guide: `https://developers.openai.com/api/docs/guides/realtime-conversations`
- OpenAI Realtime API reference: `https://developers.openai.com/api/reference/resources/realtime`
- OpenAI `gpt-realtime` model page: `https://developers.openai.com/api/docs/models/gpt-realtime`

Important API facts used by this plan:

- WebSocket URL: `wss://api.openai.com/v1/realtime?model=gpt-realtime`
- Authenticate with `Authorization: Bearer <OPENAI_API_KEY>`.
- Configure sessions with `session.update`.
- For text-only output, set `output_modalities: ["text"]`.
- WebSocket audio chunks are base64 in `input_audio_buffer.append`.
- Tool calls finalize through `response.function_call_arguments.done`.
- Function results are sent back as `conversation.item.create` with `type: "function_call_output"`, followed by `response.create` when the model should continue.

## File Structure

Create:

- `Sources/Nous/Models/Voice/VoiceModeModels.swift`
  Voice state enums, tool names, parsed tool calls, pending actions, navigation target.
- `Sources/Nous/Services/VoiceCommandController.swift`
  Main-actor controller for direct actions, confirmation queue, and Realtime event handling.
- `Sources/Nous/Services/RealtimeVoiceSession.swift`
  OpenAI Realtime WebSocket lifecycle, event parsing, event sending, and audio session bridge.
- `Sources/Nous/Services/VoiceAudioCapture.swift`
  `AVAudioEngine` capture and PCM16/24kHz/base64 conversion.
- `Sources/Nous/Services/VoiceMemoryFacade.swift`
  Small read facade for voice memory tools.
- `Sources/Nous/Views/VoiceActionPill.swift`
  Compact action/status pill with confirm/cancel controls.
- `Tests/NousTests/VoiceCommandControllerTests.swift`
- `Tests/NousTests/NoteViewModelTests.swift`
- `Tests/NousTests/RealtimeVoiceSessionTests.swift`
- `Tests/NousTests/VoiceAudioCaptureTests.swift`
- `Tests/NousTests/VoiceMemoryFacadeTests.swift`

Modify:

- `project.yml`
  Add `AVFoundation.framework` as an SDK dependency for the app target.
- `Info.plist`
  Add `NSMicrophoneUsageDescription`.
- `Sources/Nous/ViewModels/SettingsViewModel.swift`
  Add Voice Mode availability helpers.
- `Tests/NousTests/SettingsViewModelTests.swift`
  Test Voice Mode availability.
- `Sources/Nous/App/ContentView.swift`
  Own the `VoiceCommandController`, configure app actions, pass it into chat.
- `Sources/Nous/Views/ChatArea.swift`
  Render mic button and `VoiceActionPill`, configure chat-specific handlers.
- `Sources/Nous/ViewModels/NoteViewModel.swift`
  Add a narrow title/body note creation method for confirmed voice note actions.

Do not modify:

- `Sources/Nous/Resources/anchor.md`
- Existing `AgentToolRegistry` contracts except by reading underlying services through `VoiceMemoryFacade`.

---

### Task 1: Voice Models And Controller Core

**Files:**
- Create: `Sources/Nous/Models/Voice/VoiceModeModels.swift`
- Create: `Sources/Nous/Services/VoiceCommandController.swift`
- Test: `Tests/NousTests/VoiceCommandControllerTests.swift`

- [ ] **Step 1: Write failing tests for direct tools and pending actions**

Create `Tests/NousTests/VoiceCommandControllerTests.swift`:

```swift
import XCTest
@testable import Nous

@MainActor
final class VoiceCommandControllerTests: XCTestCase {
    func testNavigateToolUpdatesStatusAndCallsHandler() async throws {
        let controller = VoiceCommandController()
        var navigated: VoiceNavigationTarget?
        controller.configure(
            VoiceActionHandlers(
                navigate: { navigated = $0 },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                sendMessage: { _ in },
                createNote: { _, _ in }
            )
        )

        try await controller.handleToolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"galaxy"}"#))

        XCTAssertEqual(navigated, .galaxy)
        XCTAssertEqual(controller.status, .action("Opening Galaxy"))
        XCTAssertNil(controller.pendingAction)
    }

    func testUnknownToolIsRejectedWithoutMutation() async {
        let controller = VoiceCommandController()
        var didNavigate = false
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in didNavigate = true },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                sendMessage: { _ in },
                createNote: { _, _ in }
            )
        )

        await XCTAssertThrowsErrorAsync(
            try await controller.handleToolCall(.init(name: "click_at_point", arguments: #"{"x":10,"y":10}"#))
        ) { error in
            XCTAssertEqual(error as? VoiceToolError, .unknownTool("click_at_point"))
        }
        XCTAssertFalse(didNavigate)
        XCTAssertEqual(controller.status, .error("Voice command rejected"))
    }

    func testProposeSendCreatesPendingActionWithoutSending() async throws {
        let controller = VoiceCommandController()
        var sent: String?
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                sendMessage: { sent = $0 },
                createNote: { _, _ in }
            )
        )

        try await controller.handleToolCall(.init(name: "propose_send_message", arguments: #"{"text":"Ship the calm version."}"#))

        XCTAssertNil(sent)
        XCTAssertEqual(controller.pendingAction, .sendMessage(text: "Ship the calm version."))
        XCTAssertEqual(controller.status, .needsConfirmation("Confirm send?"))
    }

    func testConfirmExecutesPendingActionOnce() async throws {
        let controller = VoiceCommandController()
        var sentMessages: [String] = []
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                sendMessage: { sentMessages.append($0) },
                createNote: { _, _ in }
            )
        )

        try await controller.handleToolCall(.init(name: "propose_send_message", arguments: #"{"text":"Send once."}"#))
        controller.confirmPendingAction()
        controller.confirmPendingAction()

        XCTAssertEqual(sentMessages, ["Send once."])
        XCTAssertNil(controller.pendingAction)
        XCTAssertEqual(controller.status, .action("Sent"))
    }

    func testCancelClearsPendingActionWithoutExecuting() async throws {
        let controller = VoiceCommandController()
        var sent = false
        controller.configure(
            VoiceActionHandlers(
                navigate: { _ in },
                setSidebarVisible: { _ in },
                setScratchPadVisible: { _ in },
                setComposerText: { _ in },
                appendComposerText: { _ in },
                clearComposer: {},
                startNewChat: {},
                sendMessage: { _ in sent = true },
                createNote: { _, _ in }
            )
        )

        try await controller.handleToolCall(.init(name: "propose_send_message", arguments: #"{"text":"Cancel me."}"#))
        controller.cancelPendingAction()

        XCTAssertFalse(sent)
        XCTAssertNil(controller.pendingAction)
        XCTAssertEqual(controller.status, .action("Cancelled"))
    }

    func testInvalidNavigationArgumentIsRejected() async {
        let controller = VoiceCommandController()

        await XCTAssertThrowsErrorAsync(
            try await controller.handleToolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"files"}"#))
        ) { error in
            XCTAssertEqual(error as? VoiceToolError, .invalidArgument("tab"))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/VoiceCommandControllerTests
```

Expected: compile failure because `VoiceCommandController`, `VoiceActionHandlers`, `VoiceToolCall`, `VoiceNavigationTarget`, `VoiceToolError`, and `VoicePendingAction` do not exist.

- [ ] **Step 3: Add voice model types**

Create `Sources/Nous/Models/Voice/VoiceModeModels.swift`:

```swift
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
```

- [ ] **Step 4: Add controller implementation**

Create `Sources/Nous/Services/VoiceCommandController.swift`:

```swift
import Foundation
import Observation

@Observable
@MainActor
final class VoiceCommandController {
    var status: VoiceModeStatus = .idle
    var pendingAction: VoicePendingAction?
    var isActive: Bool = false

    private var handlers: VoiceActionHandlers = .empty

    func configure(_ handlers: VoiceActionHandlers) {
        self.handlers = handlers
    }

    func markListening() {
        isActive = true
        status = .listening
    }

    func stop() {
        isActive = false
        pendingAction = nil
        status = .idle
    }

    func handleToolCall(_ call: VoiceToolCall) async throws {
        let args = try Self.decodeArguments(call.arguments)

        switch call.name {
        case "navigate_to_tab":
            let raw = try requiredString("tab", in: args)
            guard let target = VoiceNavigationTarget(rawValue: raw) else {
                status = .error("Voice command rejected")
                throw VoiceToolError.invalidArgument("tab")
            }
            handlers.navigate(target)
            status = .action(target.actionTitle)

        case "set_sidebar_visibility":
            handlers.setSidebarVisible(try requiredBool("visible", in: args))
            status = .action("Updated sidebar")

        case "set_scratchpad_visibility":
            let visible = try requiredBool("visible", in: args)
            handlers.setScratchPadVisible(visible)
            status = .action(visible ? "Opening Scratchpad" : "Closing Scratchpad")

        case "set_composer_text":
            handlers.setComposerText(try requiredString("text", in: args))
            status = .action("Drafting message")

        case "append_composer_text":
            handlers.appendComposerText(try requiredString("text", in: args))
            status = .action("Drafting message")

        case "clear_composer":
            handlers.clearComposer()
            status = .action("Cleared draft")

        case "start_new_chat":
            handlers.startNewChat()
            status = .action("New chat")

        case "propose_send_message":
            pendingAction = .sendMessage(text: try requiredString("text", in: args))
            status = .needsConfirmation("Confirm send?")

        case "propose_note":
            pendingAction = .createNote(
                title: try requiredString("title", in: args),
                body: try requiredString("body", in: args)
            )
            status = .needsConfirmation("Create note?")

        case "confirm_pending_action":
            confirmPendingAction()

        case "cancel_pending_action":
            cancelPendingAction()

        default:
            status = .error("Voice command rejected")
            throw VoiceToolError.unknownTool(call.name)
        }
    }

    func confirmPendingAction() {
        guard let pendingAction else { return }
        self.pendingAction = nil

        switch pendingAction {
        case .sendMessage(let text):
            handlers.sendMessage(text)
            status = .action("Sent")
        case .createNote(let title, let body):
            handlers.createNote(title, body)
            status = .action("Created note")
        }
    }

    func cancelPendingAction() {
        pendingAction = nil
        status = .action("Cancelled")
    }

    private static func decodeArguments(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw VoiceToolError.invalidJSON
        }
        return dict
    }

    private func requiredString(_ key: String, in args: [String: Any]) throws -> String {
        guard args.keys.contains(key) else { throw VoiceToolError.missingArgument(key) }
        guard let value = args[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceToolError.invalidArgument(key)
        }
        return value
    }

    private func requiredBool(_ key: String, in args: [String: Any]) throws -> Bool {
        guard args.keys.contains(key) else { throw VoiceToolError.missingArgument(key) }
        guard let value = args[key] as? Bool else { throw VoiceToolError.invalidArgument(key) }
        return value
    }
}
```

- [ ] **Step 5: Run controller tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/VoiceCommandControllerTests
```

Expected: tests pass.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/Nous/Models/Voice/VoiceModeModels.swift Sources/Nous/Services/VoiceCommandController.swift Tests/NousTests/VoiceCommandControllerTests.swift
git commit -m "feat: add voice command controller"
```

---

### Task 2: Settings Availability And Microphone Permission Metadata

**Files:**
- Modify: `Info.plist`
- Modify: `project.yml`
- Modify: `Sources/Nous/ViewModels/SettingsViewModel.swift`
- Modify: `Tests/NousTests/SettingsViewModelTests.swift`

- [ ] **Step 1: Write failing settings tests**

Append to `SettingsViewModelTests`:

```swift
func testVoiceModeAvailabilityRequiresOpenAIKey() {
    let vm = makeViewModel()

    XCTAssertFalse(vm.isVoiceModeAvailable)
    XCTAssertEqual(vm.voiceModeUnavailableReason, "Add an OpenAI API key to use Voice Mode.")

    vm.openaiApiKey = "  openai-key  "

    XCTAssertTrue(vm.isVoiceModeAvailable)
    XCTAssertNil(vm.voiceModeUnavailableReason)
}
```

- [ ] **Step 2: Run settings test and verify failure**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/SettingsViewModelTests/testVoiceModeAvailabilityRequiresOpenAIKey
```

Expected: compile failure because `isVoiceModeAvailable` and `voiceModeUnavailableReason` do not exist.

- [ ] **Step 3: Add availability helpers**

In `Sources/Nous/ViewModels/SettingsViewModel.swift`, below `credentialStorageDescription`, add:

```swift
var isVoiceModeAvailable: Bool {
    !openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

var voiceModeUnavailableReason: String? {
    isVoiceModeAvailable ? nil : "Add an OpenAI API key to use Voice Mode."
}
```

- [ ] **Step 4: Add microphone usage description**

In `Info.plist`, add this key inside `<dict>`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Nous uses the microphone only while Voice Mode is active so you can speak commands and draft messages.</string>
```

- [ ] **Step 5: Add AVFoundation SDK dependency**

In `project.yml`, under the `Nous` target dependencies, add:

```yaml
      - sdk: AVFoundation.framework
```

Keep existing `sdk:` style for system frameworks.

- [ ] **Step 6: Regenerate the Xcode project**

Run:

```bash
xcodegen generate
```

Expected: `Nous.xcodeproj` updates cleanly.

- [ ] **Step 7: Run settings test**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/SettingsViewModelTests/testVoiceModeAvailabilityRequiresOpenAIKey
```

Expected: pass.

- [ ] **Step 8: Commit Task 2**

```bash
git add Info.plist project.yml Nous.xcodeproj Sources/Nous/ViewModels/SettingsViewModel.swift Tests/NousTests/SettingsViewModelTests.swift
git commit -m "feat: add voice mode availability"
```

---

### Task 3: Realtime Event Parser And Session Request Builder

**Files:**
- Create: `Sources/Nous/Services/RealtimeVoiceSession.swift`
- Test: `Tests/NousTests/RealtimeVoiceSessionTests.swift`

- [ ] **Step 1: Write failing parser and request tests**

Create `Tests/NousTests/RealtimeVoiceSessionTests.swift`:

```swift
import XCTest
@testable import Nous

final class RealtimeVoiceSessionTests: XCTestCase {
    func testBuildsRealtimeRequestWithBearerTokenAndModel() throws {
        let request = RealtimeVoiceSession.makeRequest(apiKey: "sk-test", model: "gpt-realtime")

        XCTAssertEqual(request.url?.absoluteString, "wss://api.openai.com/v1/realtime?model=gpt-realtime")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testSessionUpdateIncludesTextOutputAndTools() throws {
        let data = try RealtimeVoiceSession.makeSessionUpdateEvent()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try XCTUnwrap(json["session"] as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "session.update")
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertEqual(session["model"] as? String, "gpt-realtime")
        XCTAssertEqual(session["output_modalities"] as? [String], ["text"])
        XCTAssertEqual(session["tool_choice"] as? String, "auto")
        XCTAssertFalse((session["tools"] as? [[String: Any]])?.isEmpty ?? true)
    }

    func testParsesFunctionCallArgumentsDone() throws {
        let raw = """
        {
          "type": "response.function_call_arguments.done",
          "name": "navigate_to_tab",
          "call_id": "call_123",
          "arguments": "{\\"tab\\":\\"galaxy\\"}"
        }
        """

        let event = try XCTUnwrap(RealtimeVoiceEventParser.parse(raw))

        XCTAssertEqual(event, .toolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"galaxy"}"#), callId: "call_123"))
    }

    func testParsesResponseDoneAsThinkingComplete() throws {
        let raw = #"{"type":"response.done"}"#

        XCTAssertEqual(RealtimeVoiceEventParser.parse(raw), .responseDone)
    }

    func testUnknownEventsAreIgnored() throws {
        XCTAssertNil(RealtimeVoiceEventParser.parse(#"{"type":"rate_limits.updated"}"#))
    }

    func testFunctionOutputEventShape() throws {
        let data = try RealtimeVoiceSession.makeFunctionOutputEvent(callId: "call_123", output: "Opened Galaxy")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let item = try XCTUnwrap(json["item"] as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "conversation.item.create")
        XCTAssertEqual(item["type"] as? String, "function_call_output")
        XCTAssertEqual(item["call_id"] as? String, "call_123")
        XCTAssertEqual(item["output"] as? String, "Opened Galaxy")
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/RealtimeVoiceSessionTests
```

Expected: compile failure because `RealtimeVoiceSession`, `RealtimeVoiceEventParser`, and `RealtimeVoiceEvent` do not exist.

- [ ] **Step 3: Add parser and event builders**

Create `Sources/Nous/Services/RealtimeVoiceSession.swift` with parser and request-building code first. Do not start audio streaming yet.

```swift
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
            return .responseDone
        case "error":
            let error = json["error"] as? [String: Any]
            return .error(error?["message"] as? String ?? "Realtime error")
        default:
            return nil
        }
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
```

- [ ] **Step 4: Run Realtime parser tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/RealtimeVoiceSessionTests
```

Expected: pass.

- [ ] **Step 5: Commit Task 3**

```bash
git add Sources/Nous/Services/RealtimeVoiceSession.swift Tests/NousTests/RealtimeVoiceSessionTests.swift
git commit -m "feat: add realtime voice event parser"
```

---

### Task 4: Audio Capture And WebSocket Lifecycle

**Files:**
- Create: `Sources/Nous/Services/VoiceAudioCapture.swift`
- Modify: `Sources/Nous/Services/RealtimeVoiceSession.swift`
- Test: `Tests/NousTests/VoiceAudioCaptureTests.swift`
- Test: `Tests/NousTests/RealtimeVoiceSessionTests.swift`

- [ ] **Step 1: Write audio encoding unit tests**

Create `Tests/NousTests/VoiceAudioCaptureTests.swift`:

```swift
import XCTest
@testable import Nous

final class VoiceAudioCaptureTests: XCTestCase {
    func testPCM16Base64EncodingClampsSamples() {
        let samples: [Float] = [-2.0, -1.0, 0.0, 1.0, 2.0]

        let data = VoiceAudioEncoder.pcm16Data(fromMonoFloatSamples: samples)
        XCTAssertEqual(data.count, samples.count * 2)

        let values: [Int16] = stride(from: 0, to: data.count, by: 2).map { offset in
            data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)
            }
        }

        XCTAssertEqual(values[0], Int16.min)
        XCTAssertEqual(values[1], Int16.min)
        XCTAssertEqual(values[2], 0)
        XCTAssertEqual(values[3], Int16.max)
        XCTAssertEqual(values[4], Int16.max)
    }

    func testBase64AudioIsNonEmptyForNonEmptySamples() {
        let encoded = VoiceAudioEncoder.base64PCM16(fromMonoFloatSamples: [0.25, -0.25])

        XCTAssertFalse(encoded.isEmpty)
    }
}
```

- [ ] **Step 2: Add session lifecycle tests with fake socket**

Append to `RealtimeVoiceSessionTests`:

```swift
func testSessionStartSendsSessionUpdate() async throws {
    let socket = FakeRealtimeSocket()
    let session = RealtimeVoiceSession(socket: socket, audioCapture: nil)

    try await session.start(apiKey: "sk-test") { _ in }

    XCTAssertEqual(socket.sentStringEvents.count, 1)
    XCTAssertTrue(socket.sentStringEvents[0].contains(#""type":"session.update""#))
}

private final class FakeRealtimeSocket: RealtimeVoiceSocketing {
    var sentStringEvents: [String] = []
    var incoming: [String] = []

    func connect(request: URLRequest) async throws {}

    func send(_ text: String) async throws {
        sentStringEvents.append(text)
    }

    func receive() async throws -> String? {
        incoming.isEmpty ? nil : incoming.removeFirst()
    }

    func close() {}
}
```

Expected initial failure: `RealtimeVoiceSocketing`, injectable initializer, and lifecycle methods do not exist.

- [ ] **Step 3: Add audio encoder**

Create `Sources/Nous/Services/VoiceAudioCapture.swift`:

```swift
import AVFoundation
import Foundation

enum VoiceAudioEncoder {
    static func pcm16Data(fromMonoFloatSamples samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = clamped >= 0 ? clamped * Float(Int16.max) : clamped * Float(-Int16.min)
            var intSample = Int16(scaled.rounded())
            data.append(Data(bytes: &intSample, count: MemoryLayout<Int16>.size))
        }
        return data
    }

    static func base64PCM16(fromMonoFloatSamples samples: [Float]) -> String {
        pcm16Data(fromMonoFloatSamples: samples).base64EncodedString()
    }
}

final class VoiceAudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    func start(onAudio: @escaping @Sendable (String) -> Void) throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self,
                  let converted = self.convert(buffer),
                  let channel = converted.floatChannelData?[0] else { return }
            let frameCount = Int(converted.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channel, count: frameCount))
            let encoded = VoiceAudioEncoder.base64PCM16(fromMonoFloatSamples: samples)
            if !encoded.isEmpty {
                onAudio(encoded)
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
}
```

- [ ] **Step 4: Add socket abstraction and lifecycle**

Extend `Sources/Nous/Services/RealtimeVoiceSession.swift` below the existing static builder code:

```swift
protocol RealtimeVoiceSocketing: AnyObject {
    func connect(request: URLRequest) async throws
    func send(_ text: String) async throws
    func receive() async throws -> String?
    func close()
}

final class URLSessionRealtimeVoiceSocket: RealtimeVoiceSocketing {
    private var task: URLSessionWebSocketTask?

    func connect(request: URLRequest) async throws {
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task?.send(.string(text))
    }

    func receive() async throws -> String? {
        guard let task else { return nil }
        switch try await task.receive() {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8)
        @unknown default:
            return nil
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
```

Then add instance state and methods to `RealtimeVoiceSession`:

```swift
private let socket: RealtimeVoiceSocketing
private let audioCapture: VoiceAudioCapture?
private var receiveTask: Task<Void, Never>?

init(
    socket: RealtimeVoiceSocketing = URLSessionRealtimeVoiceSocket(),
    audioCapture: VoiceAudioCapture? = VoiceAudioCapture()
) {
    self.socket = socket
    self.audioCapture = audioCapture
}

func start(
    apiKey: String,
    onEvent: @escaping @MainActor (RealtimeVoiceEvent) async -> Void
) async throws {
    try await socket.connect(request: Self.makeRequest(apiKey: apiKey))
    try await socket.send(String(data: try Self.makeSessionUpdateEvent(), encoding: .utf8)!)

    receiveTask = Task { [socket] in
        while !Task.isCancelled {
            do {
                guard let raw = try await socket.receive() else { break }
                guard let event = RealtimeVoiceEventParser.parse(raw) else { continue }
                await onEvent(event)
            } catch {
                await onEvent(.error(error.localizedDescription))
                break
            }
        }
    }

    try audioCapture?.start { [weak self] base64Audio in
        guard let self else { return }
        Task {
            guard let text = String(data: try Self.makeAudioAppendEvent(base64Audio: base64Audio), encoding: .utf8) else { return }
            try await self.socket.send(text)
        }
    }
}

func sendFunctionOutput(callId: String, output: String) async throws {
    try await socket.send(String(data: try Self.makeFunctionOutputEvent(callId: callId, output: output), encoding: .utf8)!)
    try await socket.send(String(data: try Self.makeResponseCreateEvent(), encoding: .utf8)!)
}

func stop() {
    receiveTask?.cancel()
    receiveTask = nil
    audioCapture?.stop()
    socket.close()
}
```

- [ ] **Step 5: Run audio/session tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/VoiceAudioCaptureTests -only-testing:NousTests/RealtimeVoiceSessionTests
```

Expected: pass.

- [ ] **Step 6: Commit Task 4**

```bash
git add Sources/Nous/Services/VoiceAudioCapture.swift Sources/Nous/Services/RealtimeVoiceSession.swift Tests/NousTests/VoiceAudioCaptureTests.swift Tests/NousTests/RealtimeVoiceSessionTests.swift
git commit -m "feat: add realtime voice transport"
```

---

### Task 5: Connect Controller To Realtime Session

**Files:**
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`
- Modify: `Sources/Nous/Services/RealtimeVoiceSession.swift`
- Test: `Tests/NousTests/VoiceCommandControllerTests.swift`

- [ ] **Step 1: Add session protocol and controller tests**

Append to `VoiceCommandControllerTests`:

```swift
func testStartRequiresOpenAIKey() async {
    let controller = VoiceCommandController(session: FakeVoiceSession())

    await XCTAssertThrowsErrorAsync(
        try await controller.start(apiKey: "   ")
    ) { error in
        XCTAssertEqual(error as? VoiceSessionError, .missingOpenAIKey)
    }
    XCTAssertEqual(controller.status, .error("Add OpenAI API key"))
}

func testRealtimeToolCallRunsThroughControllerAndReturnsFunctionOutput() async throws {
    let session = FakeVoiceSession()
    let controller = VoiceCommandController(session: session)
    var navigated: VoiceNavigationTarget?
    controller.configure(
        VoiceActionHandlers(
            navigate: { navigated = $0 },
            setSidebarVisible: { _ in },
            setScratchPadVisible: { _ in },
            setComposerText: { _ in },
            appendComposerText: { _ in },
            clearComposer: {},
            startNewChat: {},
            sendMessage: { _ in },
            createNote: { _, _ in }
        )
    )

    try await controller.start(apiKey: "sk-test")
    await session.emit(.toolCall(.init(name: "navigate_to_tab", arguments: #"{"tab":"galaxy"}"#), callId: "call_123"))

    XCTAssertEqual(navigated, .galaxy)
    XCTAssertEqual(session.outputs, [("call_123", "Opening Galaxy")])
}

private final class FakeVoiceSession: RealtimeVoiceSessioning {
    var onEvent: (@MainActor (RealtimeVoiceEvent) async -> Void)?
    var outputs: [(String, String)] = []

    func start(apiKey: String, onEvent: @escaping @MainActor (RealtimeVoiceEvent) async -> Void) async throws {
        self.onEvent = onEvent
    }

    func sendFunctionOutput(callId: String, output: String) async throws {
        outputs.append((callId, output))
    }

    func stop() {}

    @MainActor
    func emit(_ event: RealtimeVoiceEvent) async {
        await onEvent?(event)
    }
}
```

- [ ] **Step 2: Add protocol conformance**

In `RealtimeVoiceSession.swift`, define:

```swift
protocol RealtimeVoiceSessioning: AnyObject {
    func start(apiKey: String, onEvent: @escaping @MainActor (RealtimeVoiceEvent) async -> Void) async throws
    func sendFunctionOutput(callId: String, output: String) async throws
    func stop()
}
```

Make `RealtimeVoiceSession` conform:

```swift
final class RealtimeVoiceSession: RealtimeVoiceSessioning {
    ...
}
```

- [ ] **Step 3: Add session start/stop to controller**

In `VoiceCommandController.swift`, add:

```swift
enum VoiceSessionError: Error, Equatable {
    case missingOpenAIKey
}
```

Add properties and initializer:

```swift
private let session: RealtimeVoiceSessioning

init(session: RealtimeVoiceSessioning = RealtimeVoiceSession()) {
    self.session = session
}
```

Add methods:

```swift
func start(apiKey: String) async throws {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        status = .error("Add OpenAI API key")
        throw VoiceSessionError.missingOpenAIKey
    }

    markListening()
    do {
        try await session.start(apiKey: trimmed) { [weak self] event in
            await self?.handleRealtimeEvent(event)
        }
    } catch {
        status = .error("Voice unavailable")
        isActive = false
        throw error
    }
}

func handleRealtimeEvent(_ event: RealtimeVoiceEvent) async {
    switch event {
    case .sessionReady:
        status = .listening
    case .toolCall(let call, let callId):
        do {
            try await handleToolCall(call)
            try await session.sendFunctionOutput(callId: callId, output: status.displayText)
        } catch {
            try? await session.sendFunctionOutput(callId: callId, output: "Voice command rejected")
        }
    case .responseDone:
        if pendingAction == nil {
            status = .listening
        }
    case .error:
        status = .error("Voice unavailable")
    }
}
```

Update existing `stop()`:

```swift
func stop() {
    session.stop()
    isActive = false
    pendingAction = nil
    status = .idle
}
```

- [ ] **Step 4: Run controller tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/VoiceCommandControllerTests
```

Expected: pass.

- [ ] **Step 5: Commit Task 5**

```bash
git add Sources/Nous/Services/VoiceCommandController.swift Sources/Nous/Services/RealtimeVoiceSession.swift Tests/NousTests/VoiceCommandControllerTests.swift
git commit -m "feat: wire voice controller to realtime session"
```

---

### Task 6: Voice Memory Facade

**Files:**
- Create: `Sources/Nous/Services/VoiceMemoryFacade.swift`
- Modify: `Sources/Nous/Services/RealtimeVoiceSession.swift`
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`
- Test: `Tests/NousTests/VoiceMemoryFacadeTests.swift`
- Test: `Tests/NousTests/VoiceCommandControllerTests.swift`

- [ ] **Step 1: Write facade tests**

Create `Tests/NousTests/VoiceMemoryFacadeTests.swift`:

```swift
import XCTest
@testable import Nous

final class VoiceMemoryFacadeTests: XCTestCase {
    private var store: NodeStore!
    private var conversationId: UUID!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try NodeStore(path: ":memory:")
        let conversation = NousNode(type: .conversation, title: "Current")
        conversationId = conversation.id
        try store.insertNode(conversation)
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    func testRecallRecentConversationsReturnsBoundedSummary() throws {
        let previous = NousNode(type: .conversation, title: "Previous")
        try store.insertNode(previous)
        try store.insertMemoryEntry(MemoryEntry(
            scope: .conversation,
            scopeRefId: previous.id,
            kind: .thread,
            stability: .stable,
            content: "Alex decided to keep the interface calm."
        ))

        let facade = VoiceMemoryFacade(nodeStore: store)
        let output = try facade.recallRecentConversations(
            limit: 1,
            context: VoiceMemoryContext(projectId: nil, conversationId: conversationId)
        )

        XCTAssertTrue(output.contains("Previous"))
        XCTAssertTrue(output.contains("calm"))
        XCTAssertLessThanOrEqual(output.count, 1200)
    }

    func testSearchMemoryReturnsFriendlyEmptyState() throws {
        let facade = VoiceMemoryFacade(nodeStore: store)

        XCTAssertEqual(
            try facade.searchMemory(
                query: "visa",
                limit: 5,
                context: VoiceMemoryContext(projectId: nil, conversationId: conversationId)
            ),
            "No matching memory found."
        )
    }

    func testSearchMemoryUsesExistingScopedMemorySearch() throws {
        try store.insertMemoryEntry(MemoryEntry(
            scope: .global,
            kind: .decision,
            stability: .stable,
            content: "Use voice mode for fast capture, not novelty."
        ))

        let facade = VoiceMemoryFacade(nodeStore: store)
        let output = try facade.searchMemory(
            query: "voice capture",
            limit: 5,
            context: VoiceMemoryContext(projectId: nil, conversationId: conversationId)
        )

        XCTAssertTrue(output.contains("voice mode"))
        XCTAssertTrue(output.contains("decision"))
    }
}
```

- [ ] **Step 2: Add controller tests for memory tools**

Append to `VoiceCommandControllerTests`:

```swift
func testSearchMemoryToolReturnsFacadeOutput() async throws {
    let memory = FakeVoiceMemory(searchOutput: "Memory: stay focused.", recentOutput: "")
    let session = FakeVoiceSession()
    let controller = VoiceCommandController(session: session, memory: memory)
    controller.setMemoryContextProvider {
        VoiceMemoryContext(projectId: nil, conversationId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    }

    try await controller.start(apiKey: "sk-test")
    await session.emit(.toolCall(.init(name: "search_memory", arguments: #"{"query":"focus","limit":2}"#), callId: "call_memory"))

    XCTAssertEqual(session.outputs, [("call_memory", "Memory: stay focused.")])
    XCTAssertEqual(controller.status, .action("Searching memory"))
}

private struct FakeVoiceMemory: VoiceMemorySearching {
    let searchOutput: String
    let recentOutput: String

    func searchMemory(query: String, limit: Int, context: VoiceMemoryContext) throws -> String { searchOutput }
    func recallRecentConversations(limit: Int, context: VoiceMemoryContext) throws -> String { recentOutput }
}
```

- [ ] **Step 3: Add facade implementation**

Create `Sources/Nous/Services/VoiceMemoryFacade.swift`:

```swift
import Foundation

protocol VoiceMemorySearching {
    func searchMemory(query: String, limit: Int, context: VoiceMemoryContext) throws -> String
    func recallRecentConversations(limit: Int, context: VoiceMemoryContext) throws -> String
}

struct VoiceMemoryContext: Equatable {
    let projectId: UUID?
    let conversationId: UUID
}

final class VoiceMemoryFacade: VoiceMemorySearching {
    private let memorySearchProvider: any MemoryEntrySearchProviding
    private let recentProvider: any RecentConversationMemoryProviding
    private let maxCharacters: Int

    init(nodeStore: NodeStore, maxCharacters: Int = 1200) {
        self.memorySearchProvider = nodeStore
        self.recentProvider = nodeStore
        self.maxCharacters = maxCharacters
    }

    func searchMemory(query: String, limit: Int, context: VoiceMemoryContext) throws -> String {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return "No matching memory found." }

        let entries = try memorySearchProvider.searchActiveMemoryEntries(
            query: normalized,
            projectId: context.projectId,
            conversationId: context.conversationId,
            limit: bounded(limit, 1...5)
        )
        guard !entries.isEmpty else { return "No matching memory found." }

        return clamp(entries.map { entry in
            "- \(entry.kind.rawValue): \(entry.content)"
        }.joined(separator: "\n"))
    }

    func recallRecentConversations(limit: Int, context: VoiceMemoryContext) throws -> String {
        let memories = try recentProvider.fetchRecentConversationMemories(
            limit: bounded(limit, 1...5),
            excludingId: context.conversationId
        )

        guard !memories.isEmpty else { return "No recent conversations found." }

        return clamp(memories.map { memory in
            "- \(memory.title): \(memory.memory.prefix(360))"
        }.joined(separator: "\n"))
    }

    private func bounded(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func clamp(_ text: String) -> String {
        if text.count <= maxCharacters { return text }
        return String(text.prefix(maxCharacters)) + "..."
    }
}
```

- [ ] **Step 4: Add memory tool declarations**

In `RealtimeVoiceSession.voiceToolDeclarations`, add:

```swift
functionTool(
    name: "search_memory",
    description: "Search Nous memory for short relevant context.",
    properties: [
        "query": ["type": "string"],
        "limit": ["type": "integer"]
    ],
    required: ["query"]
),
functionTool(
    name: "recall_recent_conversations",
    description: "Recall recent Nous conversations.",
    properties: ["limit": ["type": "integer"]],
    required: []
)
```

- [ ] **Step 5: Wire memory tools into controller**

In `VoiceCommandController`, add:

```swift
private let memory: VoiceMemorySearching?
private var memoryContextProvider: () -> VoiceMemoryContext? = { nil }

init(
    session: RealtimeVoiceSessioning = RealtimeVoiceSession(),
    memory: VoiceMemorySearching? = nil
) {
    self.session = session
    self.memory = memory
}
```

Add:

```swift
func setMemoryContextProvider(_ provider: @escaping () -> VoiceMemoryContext?) {
    self.memoryContextProvider = provider
}
```

Add switch cases:

```swift
case "search_memory":
    guard let memory else {
        status = .error("Memory unavailable")
        throw VoiceToolError.unknownTool(call.name)
    }
    status = .action("Searching memory")
    let query = try requiredString("query", in: args)
    let limit = optionalInt("limit", in: args, default: 3, range: 1...5)
    guard let context = memoryContextProvider() else {
        lastToolOutput = "No active conversation memory context."
        return
    }
    lastToolOutput = try memory.searchMemory(query: query, limit: limit, context: context)

case "recall_recent_conversations":
    guard let memory else {
        status = .error("Memory unavailable")
        throw VoiceToolError.unknownTool(call.name)
    }
    status = .action("Recalling recent chats")
    let limit = optionalInt("limit", in: args, default: 3, range: 1...5)
    guard let context = memoryContextProvider() else {
        lastToolOutput = "No active conversation memory context."
        return
    }
    lastToolOutput = try memory.recallRecentConversations(limit: limit, context: context)
```

Add `private var lastToolOutput: String?` and change `handleRealtimeEvent` output to:

```swift
let output = lastToolOutput ?? status.displayText
lastToolOutput = nil
try await session.sendFunctionOutput(callId: callId, output: output)
```

Add helper:

```swift
private func optionalInt(_ key: String, in args: [String: Any], default defaultValue: Int, range: ClosedRange<Int>) -> Int {
    guard let raw = args[key] else { return defaultValue }
    let value: Int
    if let int = raw as? Int {
        value = int
    } else if let double = raw as? Double {
        value = Int(double)
    } else {
        return defaultValue
    }
    return min(max(value, range.lowerBound), range.upperBound)
}
```

- [ ] **Step 6: Run memory tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/VoiceMemoryFacadeTests -only-testing:NousTests/VoiceCommandControllerTests/testSearchMemoryToolReturnsFacadeOutput
```

Expected: pass.

- [ ] **Step 7: Commit Task 6**

```bash
git add Sources/Nous/Services/VoiceMemoryFacade.swift Sources/Nous/Services/RealtimeVoiceSession.swift Sources/Nous/Services/VoiceCommandController.swift Tests/NousTests/VoiceMemoryFacadeTests.swift Tests/NousTests/VoiceCommandControllerTests.swift
git commit -m "feat: add voice memory tools"
```

---

### Task 7: SwiftUI Voice Entry Point And Action Pill

**Files:**
- Create: `Sources/Nous/Views/VoiceActionPill.swift`
- Modify: `Sources/Nous/App/AppEnvironment.swift`
- Modify: `Sources/Nous/App/ContentView.swift`
- Modify: `Sources/Nous/Views/ChatArea.swift`
- Modify: `Sources/Nous/ViewModels/NoteViewModel.swift`
- Test: `Tests/NousTests/NoteViewModelTests.swift`

- [ ] **Step 1: Write a note creation test for confirmed voice notes**

Create `Tests/NousTests/NoteViewModelTests.swift`:

```swift
import XCTest
@testable import Nous

final class NoteViewModelTests: XCTestCase {
    private var store: NodeStore!
    private var vm: NoteViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: store)
        vm = NoteViewModel(
            nodeStore: store,
            vectorStore: vectorStore,
            embeddingService: EmbeddingService(),
            graphEngine: GraphEngine(nodeStore: store, vectorStore: vectorStore)
        )
    }

    override func tearDownWithError() throws {
        vm = nil
        store = nil
        try super.tearDownWithError()
    }

    func testCreateNoteWithTitleAndContentPersistsAndOpensNote() throws {
        try vm.createNote(title: "Voice Note", content: "Captured by voice.", projectId: nil)

        XCTAssertEqual(vm.currentNote?.title, "Voice Note")
        XCTAssertEqual(vm.title, "Voice Note")
        XCTAssertEqual(vm.content, "Captured by voice.")

        let notes = try store.fetchAllNodes().filter { $0.type == .note }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.title, "Voice Note")
        XCTAssertEqual(notes.first?.content, "Captured by voice.")
    }

    func testCreateNoteWithBlankTitleFallsBackToUntitled() throws {
        try vm.createNote(title: "   ", content: "Body", projectId: nil)

        XCTAssertEqual(vm.currentNote?.title, "Untitled")
        XCTAssertEqual(vm.content, "Body")
    }
}
```

- [ ] **Step 2: Add the narrow note creation method**

In `Sources/Nous/ViewModels/NoteViewModel.swift`, keep the existing `createNote(projectId:)` and add this overload below it:

```swift
func createNote(title: String, content: String, projectId: UUID? = nil) throws {
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let node = NousNode(
        type: .note,
        title: cleanTitle.isEmpty ? "Untitled" : cleanTitle,
        content: content,
        projectId: projectId
    )
    try nodeStore.insertNode(node)
    loadNotes()
    openNote(node)
    scheduleEmbedding()
}
```

- [ ] **Step 3: Run the note test**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/NoteViewModelTests
```

Expected: pass.

- [ ] **Step 4: Add the pill view**

Create `Sources/Nous/Views/VoiceActionPill.swift`:

```swift
import SwiftUI

struct VoiceActionPill: View {
    let status: VoiceModeStatus
    let hasPendingConfirmation: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FrameSpinner(isAnimating: status == .listening || status == .thinking)
                .frame(width: 14, height: 14)

            Text(status.displayText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(AppColor.colaDarkText)
                .lineLimit(1)

            if hasPendingConfirmation {
                Button("Confirm", action: onConfirm)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColor.colaOrange)

                Button("Cancel", action: onCancel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            NativeGlassPanel(cornerRadius: 18, tintColor: AppColor.glassTint) { EmptyView() }
        )
        .overlay(
            Capsule()
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
    }
}
```

- [ ] **Step 5: Add Voice Mode dependency construction**

In `AppDependencies`, add:

```swift
let voiceController: VoiceCommandController
```

In `makeDependencies()`, after `userMemoryService` and before returning dependencies:

```swift
let voiceMemoryFacade = VoiceMemoryFacade(nodeStore: nodeStore)
let voiceController = VoiceCommandController(memory: voiceMemoryFacade)
```

Add `voiceController: voiceController` to `AppDependencies(...)`.

- [ ] **Step 6: Configure app-level voice handlers in `ContentView`**

In `ChatArea(...)` call site, pass:

```swift
voiceController: dependencies.voiceController,
openAIAPIKey: dependencies.settingsVM.openaiApiKey,
voiceUnavailableReason: dependencies.settingsVM.voiceModeUnavailableReason,
onVoiceNavigate: { target in
    switch target {
    case .chat: selectedTab = .chat
    case .notes: selectedTab = .notes
    case .galaxy: selectedTab = .galaxy
    case .settings: selectedTab = .settings
    }
},
onVoiceCreateNote: { title, body in
    do {
        try dependencies.noteVM.createNote(title: title, content: body, projectId: selectedProjectId)
        selectedTab = .notes
    } catch {
        dependencies.voiceController.status = .error("Could not create note")
    }
}
```

- [ ] **Step 7: Extend `ChatArea` inputs and configure handlers**

At the top of `ChatArea`, add properties:

```swift
@Bindable var voiceController: VoiceCommandController
let openAIAPIKey: String
let voiceUnavailableReason: String?
let onVoiceNavigate: (VoiceNavigationTarget) -> Void
let onVoiceCreateNote: (String, String) -> Void
```

In `body`, add `.onAppear` or `.task(id: vm.currentNode?.id)` to configure handlers:

```swift
.onAppear {
    configureVoiceHandlers()
}
```

Add helper:

```swift
private func configureVoiceHandlers() {
    voiceController.setMemoryContextProvider {
        guard let conversationId = vm.currentNode?.id else { return nil }
        return VoiceMemoryContext(
            projectId: vm.currentNode?.projectId ?? vm.defaultProjectId,
            conversationId: conversationId
        )
    }
    voiceController.configure(
        VoiceActionHandlers(
            navigate: onVoiceNavigate,
            setSidebarVisible: { isSidebarVisible = $0 },
            setScratchPadVisible: { isScratchPadVisible = $0 },
            setComposerText: { vm.inputText = $0 },
            appendComposerText: { text in
                if vm.inputText.isEmpty {
                    vm.inputText = text
                } else {
                    vm.inputText += "\n" + text
                }
            },
            clearComposer: { vm.inputText = "" },
            startNewChat: {
                vm.stopGenerating()
                vm.currentNode = nil
                vm.messages = []
                vm.citations = []
                vm.currentResponse = ""
                vm.inputText = ""
            },
            sendMessage: sendTextFromVoice,
            createNote: onVoiceCreateNote
        )
    )
}
```

Add this helper near `sendCurrentInput()`:

```swift
private func sendTextFromVoice(_ text: String) {
    vm.inputText = text
    attachments = []
    Task { await vm.send(attachments: []) }
}
```

- [ ] **Step 8: Add mic button and pill near the composer**

Inside the composer `HStack`, before the plus button or after it, add:

```swift
Button(action: toggleVoiceMode) {
    NativeGlassPanel(
        cornerRadius: 18,
        tintColor: voiceController.isActive
            ? NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.22)
            : AppColor.glassTint
    ) { EmptyView() }
    .frame(width: 36, height: 36)
    .overlay(
        Image(systemName: voiceController.isActive ? "mic.fill" : "mic")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(voiceController.isActive ? AppColor.colaOrange : AppColor.secondaryText)
    )
    .overlay(Circle().stroke(AppColor.panelStroke, lineWidth: 1))
}
.buttonStyle(.plain)
.help(voiceUnavailableReason ?? (voiceController.isActive ? "Stop Voice Mode" : "Start Voice Mode"))
.disabled(voiceUnavailableReason != nil)
```

Above the composer `HStack`, after clarification/attachments blocks, add:

```swift
if voiceController.isActive || voiceController.pendingAction != nil {
    VoiceActionPill(
        status: voiceController.status,
        hasPendingConfirmation: voiceController.pendingAction != nil,
        onConfirm: voiceController.confirmPendingAction,
        onCancel: voiceController.cancelPendingAction
    )
}
```

Add helper:

```swift
private func toggleVoiceMode() {
    if voiceController.isActive {
        voiceController.stop()
        return
    }

    Task {
        try? await voiceController.start(apiKey: openAIAPIKey)
    }
}
```

- [ ] **Step 9: Build the app**

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build
```

Expected: build succeeds without changing `WelcomeView`. Voice Mode v1 enters from the main chat composer, and welcome-state parity is deferred.

- [ ] **Step 10: Commit Task 7**

```bash
git add Sources/Nous/Views/VoiceActionPill.swift Sources/Nous/App/AppEnvironment.swift Sources/Nous/App/ContentView.swift Sources/Nous/Views/ChatArea.swift Sources/Nous/ViewModels/NoteViewModel.swift Tests/NousTests/NoteViewModelTests.swift
git commit -m "feat: add voice mode chat UI"
```

---

### Task 8: Verification And Manual QA

**Files:**
- No planned file edits. If verification fails, return to the specific task that introduced the failing file and repeat that task's test/fix loop.

- [ ] **Step 1: Run targeted voice tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/VoiceCommandControllerTests -only-testing:NousTests/RealtimeVoiceSessionTests -only-testing:NousTests/VoiceAudioCaptureTests -only-testing:NousTests/VoiceMemoryFacadeTests -only-testing:NousTests/NoteViewModelTests -only-testing:NousTests/SettingsViewModelTests/testVoiceModeAvailabilityRequiresOpenAIKey
```

Expected: pass.

- [ ] **Step 2: Run full test suite**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'
```

Expected: pass. If macOS 26 SDK or Metal Toolchain is missing, stop verification and record the exact environment error; do not report tests as passing.

- [ ] **Step 3: Run app build**

Run:

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build
```

Expected: build succeeds.

- [ ] **Step 4: iCloud orphan check**

Run:

```bash
find Sources/Nous -maxdepth 1 -name "*.swift"
```

Expected: no Swift files in `Sources/Nous` root.

- [ ] **Step 5: Manual QA**

Launch the app from Xcode or the built product and verify:

1. With no OpenAI key, mic button is disabled and tooltip explains why.
2. With an OpenAI key, clicking mic shows microphone permission prompt on first use.
3. After permission, pill shows `Listening`.
4. Say "open Galaxy"; pill shows `Opening Galaxy` and selected tab changes.
5. Say "open scratchpad"; scratchpad panel appears.
6. Say a short message and "send it"; pending confirmation appears before send.
7. Cancel pending send; no message is persisted.
8. Confirm pending send; normal `ChatViewModel.send` pipeline runs.
9. Stop Voice Mode; microphone/WebSocket stop and pill disappears.

- [ ] **Step 6: Final diff review**

Run:

```bash
git diff origin/main...
git status --short
```

Expected: Voice Mode files and the earlier design/plan docs are the only intentional additions for this feature. Existing unrelated user changes remain untouched.

- [ ] **Step 7: Resolve failures through the owning task**

If a verification step fails, do not create a broad stabilization commit. Go back to the task that owns the failing file, make the smallest correction there, re-run that task's targeted test command, and amend that task's commit with:

```bash
git commit --amend --no-edit
```

Expected: history stays organized by the task-level commits above.

---

## Self-Review

- **Spec coverage:** The plan covers native implementation, OpenAI Realtime WebSocket, app-owned tools, action pill, confirmation queue, privacy/microphone permission, settings availability, and tests.
- **Scope control:** Assistant audio output, WebView/React, ghost cursor, destructive tools, and always-on listening remain out of scope.
- **Type consistency:** `VoiceCommandController`, `RealtimeVoiceSession`, `VoiceActionHandlers`, `VoicePendingAction`, `VoiceModeStatus`, and `VoiceNavigationTarget` are consistently named across tasks.
- **Risk note:** The highest-risk area is native audio conversion and microphone permission behavior; Task 4 keeps conversion testable without a live microphone before UI work starts.
