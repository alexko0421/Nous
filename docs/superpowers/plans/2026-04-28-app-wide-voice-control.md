# App-Wide Voice Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing microphone button into a persistent app-wide Voice Mode that controls Nous through app-owned actions and exposes current app state to the Realtime model.

**Architecture:** Keep `RealtimeVoiceSession` as transport only, move the voice tool catalog into `VoiceActionRegistry`, and keep state mutation in `ContentView` through `VoiceActionHandlers`. `VoiceCommandController` remains the main actor coordinator for session state, pending confirmations, and tool execution.

**Tech Stack:** Swift 6.3, SwiftUI, Observation, OpenAI Realtime WebSocket, AVFoundation, XCTest, xcodegen.

---

## File Structure

- Create: `Sources/Nous/Services/VoiceActionRegistry.swift`
  - Owns voice tool declarations, risk metadata, and reusable function-tool JSON shape.
- Modify: `Sources/Nous/Models/Voice/VoiceModeModels.swift`
  - Adds `VoiceActionRisk`, `VoiceAppSnapshot`, and an app-state provider closure on `VoiceActionHandlers`.
- Modify: `Sources/Nous/Services/RealtimeVoiceSession.swift`
  - Pulls tool declarations from `VoiceActionRegistry` instead of hard-coded local arrays.
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`
  - Handles `get_app_state`, uses the new snapshot provider, and keeps existing tool behavior intact.
- Modify: `Sources/Nous/App/ContentView.swift`
  - Supplies a live app snapshot from SwiftUI state and existing ViewModels.
- Create: `Tests/NousTests/VoiceActionRegistryTests.swift`
  - Covers catalog shape, risk metadata, memory-tool gating, and snapshot JSON.
- Modify: `Tests/NousTests/RealtimeVoiceSessionTests.swift`
  - Verifies session update includes `get_app_state` and still gates memory tools.
- Modify: `Tests/NousTests/VoiceCommandControllerTests.swift`
  - Verifies `get_app_state` returns app state without mutating UI and that existing direct/confirmation tools still work.

No `project.yml` changes are needed because targets already use `sources: [Sources/Nous]` and `sources: [Tests/NousTests]`. Run `xcodegen generate` after creating new Swift files so `Nous.xcodeproj` includes them.

---

### Task 1: Add Registry and Snapshot Failing Tests

**Files:**
- Create: `Tests/NousTests/VoiceActionRegistryTests.swift`

- [ ] **Step 1: Write the failing registry tests**

Create `Tests/NousTests/VoiceActionRegistryTests.swift` with this content:

```swift
import XCTest
@testable import Nous

final class VoiceActionRegistryTests: XCTestCase {
    func testBaseCatalogIncludesAppStateAndDirectToolsWithoutMemoryTools() throws {
        let declarations = VoiceActionRegistry.declarations(includeMemoryTools: false)
        let names = try Self.toolNames(from: declarations)

        XCTAssertTrue(names.contains("get_app_state"))
        XCTAssertTrue(names.contains("navigate_to_tab"))
        XCTAssertTrue(names.contains("open_settings_section"))
        XCTAssertTrue(names.contains("set_appearance_mode"))
        XCTAssertTrue(names.contains("set_composer_text"))
        XCTAssertTrue(names.contains("propose_send_message"))
        XCTAssertTrue(names.contains("confirm_pending_action"))
        XCTAssertFalse(names.contains("search_memory"))
        XCTAssertFalse(names.contains("recall_recent_conversations"))
    }

    func testMemoryToolsAreIncludedOnlyWhenRequested() throws {
        let declarations = VoiceActionRegistry.declarations(includeMemoryTools: true)
        let names = try Self.toolNames(from: declarations)

        XCTAssertTrue(names.contains("search_memory"))
        XCTAssertTrue(names.contains("recall_recent_conversations"))
    }

    func testRiskMetadataSeparatesReadOnlyDirectAndConfirmationActions() {
        XCTAssertEqual(VoiceActionRegistry.risk(for: "get_app_state"), .readOnly)
        XCTAssertEqual(VoiceActionRegistry.risk(for: "search_memory"), .readOnly)
        XCTAssertEqual(VoiceActionRegistry.risk(for: "navigate_to_tab"), .direct)
        XCTAssertEqual(VoiceActionRegistry.risk(for: "set_composer_text"), .direct)
        XCTAssertEqual(VoiceActionRegistry.risk(for: "propose_send_message"), .confirmationRequired)
        XCTAssertEqual(VoiceActionRegistry.risk(for: "propose_note"), .confirmationRequired)
        XCTAssertNil(VoiceActionRegistry.risk(for: "click_at_point"))
    }

    func testAppSnapshotEncodesStableJSON() throws {
        let snapshot = VoiceAppSnapshot(
            currentTab: .settings,
            settingsSection: .models,
            composerText: "Review voice control",
            selectedProjectName: "New York",
            sidebarVisible: true,
            scratchpadVisible: false,
            activeConversationTitle: "Voice mode"
        )

        let data = try XCTUnwrap(snapshot.jsonString().data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["current_tab"] as? String, "settings")
        XCTAssertEqual(json["settings_section"] as? String, "models")
        XCTAssertEqual(json["composer_text"] as? String, "Review voice control")
        XCTAssertEqual(json["selected_project_name"] as? String, "New York")
        XCTAssertEqual(json["sidebar_visible"] as? Bool, true)
        XCTAssertEqual(json["scratchpad_visible"] as? Bool, false)
        XCTAssertEqual(json["active_conversation_title"] as? String, "Voice mode")
    }

    private static func toolNames(from declarations: [[String: Any]]) throws -> Set<String> {
        Set(try declarations.map { declaration in
            try XCTUnwrap(declaration["name"] as? String)
        })
    }
}
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```bash
xcodegen generate
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -derivedDataPath .context/DerivedDataAppWideVoice EXCLUDED_SOURCE_FILE_NAMES=SkillPayloadCodableTests.swift -only-testing:NousTests/VoiceActionRegistryTests
```

Expected: build fails because `VoiceActionRegistry`, `VoiceAppSnapshot`, and `VoiceActionRisk` do not exist yet.

- [ ] **Step 3: Commit the failing tests**

```bash
git add Tests/NousTests/VoiceActionRegistryTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "test: define app-wide voice action registry contract"
```

---

### Task 2: Add Voice Action Models and Registry

**Files:**
- Modify: `Sources/Nous/Models/Voice/VoiceModeModels.swift`
- Create: `Sources/Nous/Services/VoiceActionRegistry.swift`

- [ ] **Step 1: Add shared model types**

In `Sources/Nous/Models/Voice/VoiceModeModels.swift`, add these types after `VoicePendingAction`:

```swift
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
```

In the same file, update `VoiceActionHandlers` by adding this stored property:

```swift
var appSnapshot: () -> VoiceAppSnapshot
```

Update its initializer signature by adding this parameter at the end with a default:

```swift
appSnapshot: @escaping () -> VoiceAppSnapshot = { .empty }
```

Assign it in the initializer:

```swift
self.appSnapshot = appSnapshot
```

Update `VoiceActionHandlers.empty` by adding:

```swift
appSnapshot: { .empty }
```

- [ ] **Step 2: Create the registry**

Create `Sources/Nous/Services/VoiceActionRegistry.swift` with this content:

```swift
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
        tools(includeMemoryTools: true).first { $0.name == toolName }?.risk
    }

    static func tools(includeMemoryTools: Bool) -> [Tool] {
        includeMemoryTools ? baseTools + memoryTools : baseTools
    }

    private static let baseTools: [Tool] = [
        Tool(
            name: "get_app_state",
            description: "Inspect the current Nous screen, selected state, composer text, and visible panels before choosing another action.",
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
            name: "propose_send_message",
            description: "Propose sending a chat message. The app will ask for confirmation.",
            properties: ["text": ["type": "string"]],
            required: ["text"],
            risk: .confirmationRequired
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
```

- [ ] **Step 3: Regenerate the project and run the registry tests**

Run:

```bash
xcodegen generate
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -derivedDataPath .context/DerivedDataAppWideVoice EXCLUDED_SOURCE_FILE_NAMES=SkillPayloadCodableTests.swift -only-testing:NousTests/VoiceActionRegistryTests
```

Expected: `VoiceActionRegistryTests` passes with 4 tests and 0 failures.

- [ ] **Step 4: Commit the model and registry**

```bash
git add Sources/Nous/Models/Voice/VoiceModeModels.swift Sources/Nous/Services/VoiceActionRegistry.swift Tests/NousTests/VoiceActionRegistryTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "feat: add voice action registry"
```

---

### Task 3: Wire Realtime Tool Declarations to the Registry

**Files:**
- Modify: `Sources/Nous/Services/RealtimeVoiceSession.swift`
- Modify: `Tests/NousTests/RealtimeVoiceSessionTests.swift`

- [ ] **Step 1: Add the failing Realtime test assertion**

In `Tests/NousTests/RealtimeVoiceSessionTests.swift`, update `testSessionUpdateIncludesAudioOutputAndTools` by adding this assertion after `XCTAssertFalse(toolNames.isEmpty)`:

```swift
XCTAssertTrue(toolNames.contains("get_app_state"))
```

- [ ] **Step 2: Run the focused Realtime test and verify it fails**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -derivedDataPath .context/DerivedDataAppWideVoice EXCLUDED_SOURCE_FILE_NAMES=SkillPayloadCodableTests.swift -only-testing:NousTests/RealtimeVoiceSessionTests/testSessionUpdateIncludesAudioOutputAndTools
```

Expected: fails because `RealtimeVoiceSession` still uses its local hard-coded tool declaration arrays.

- [ ] **Step 3: Replace the hard-coded Realtime declaration source**

In `Sources/Nous/Services/RealtimeVoiceSession.swift`, change the session update body line from:

```swift
"tools": voiceToolDeclarations(includeMemoryTools: includeMemoryTools),
```

to:

```swift
"tools": VoiceActionRegistry.declarations(includeMemoryTools: includeMemoryTools),
```

Then delete these four private declarations from `RealtimeVoiceSession`:

```text
voiceToolDeclarations(includeMemoryTools:)
baseVoiceToolDeclarations
memoryVoiceToolDeclarations
functionTool(name:description:properties:required:)
```

Do not delete `voiceInstructions` or `audioOutputConfiguration`.

- [ ] **Step 4: Run Realtime session tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -derivedDataPath .context/DerivedDataAppWideVoice EXCLUDED_SOURCE_FILE_NAMES=SkillPayloadCodableTests.swift -only-testing:NousTests/RealtimeVoiceSessionTests
```

Expected: `RealtimeVoiceSessionTests` passes. The existing memory gating test should still show `search_memory` and `recall_recent_conversations` only when `includeMemoryTools` is true.

- [ ] **Step 5: Commit the Realtime wiring**

```bash
git add Sources/Nous/Services/RealtimeVoiceSession.swift Tests/NousTests/RealtimeVoiceSessionTests.swift
git commit -m "feat: source realtime voice tools from registry"
```

---

### Task 4: Add `get_app_state` Execution to the Controller

**Files:**
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`
- Modify: `Tests/NousTests/VoiceCommandControllerTests.swift`

- [ ] **Step 1: Add the failing controller test**

Add this test to `VoiceCommandControllerTests` near the existing Realtime tool-call tests:

```swift
func testGetAppStateReturnsSnapshotToolOutput() async throws {
    let session = FakeRealtimeVoiceSession()
    let controller = VoiceCommandController(session: session)
    controller.configure(
        VoiceActionHandlers(
            navigate: { _ in },
            setSidebarVisible: { _ in },
            setScratchPadVisible: { _ in },
            setComposerText: { _ in },
            appendComposerText: { _ in },
            clearComposer: {},
            startNewChat: {},
            sendMessage: { _ in },
            createNote: { _, _ in },
            appSnapshot: {
                VoiceAppSnapshot(
                    currentTab: .settings,
                    settingsSection: .models,
                    composerText: "Draft from voice",
                    selectedProjectName: "New York",
                    sidebarVisible: true,
                    scratchpadVisible: false,
                    activeConversationTitle: "Voice mode"
                )
            }
        )
    )

    try await controller.start(apiKey: "sk-test")
    await session.emit(.toolCall(.init(name: "get_app_state", arguments: #"{}"#), callId: "call-state"))

    let output = try XCTUnwrap(session.functionOutputs.first?.output)
    let data = try XCTUnwrap(output.data(using: .utf8))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(controller.status, .action("Reading app state"))
    XCTAssertEqual(json["current_tab"] as? String, "settings")
    XCTAssertEqual(json["settings_section"] as? String, "models")
    XCTAssertEqual(json["composer_text"] as? String, "Draft from voice")
    XCTAssertEqual(json["selected_project_name"] as? String, "New York")
    XCTAssertEqual(json["sidebar_visible"] as? Bool, true)
    XCTAssertEqual(json["scratchpad_visible"] as? Bool, false)
    XCTAssertEqual(json["active_conversation_title"] as? String, "Voice mode")
}
```

- [ ] **Step 2: Run the new controller test and verify it fails**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -derivedDataPath .context/DerivedDataAppWideVoice EXCLUDED_SOURCE_FILE_NAMES=SkillPayloadCodableTests.swift -only-testing:NousTests/VoiceCommandControllerTests/testGetAppStateReturnsSnapshotToolOutput
```

Expected: fails because `VoiceCommandController.handleToolCall` does not handle `get_app_state`.

- [ ] **Step 3: Implement `get_app_state`**

In `Sources/Nous/Services/VoiceCommandController.swift`, add this case as the first case inside `handleToolCall(_:)`:

```swift
case "get_app_state":
    lastToolOutput = try handlers.appSnapshot().jsonString()
    status = .action("Reading app state")
```

Keep all existing cases unchanged.

- [ ] **Step 4: Run controller tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -derivedDataPath .context/DerivedDataAppWideVoice EXCLUDED_SOURCE_FILE_NAMES=SkillPayloadCodableTests.swift -only-testing:NousTests/VoiceCommandControllerTests
```

Expected: `VoiceCommandControllerTests` passes. Existing tests for navigation, settings, appearance, memory search, pending confirmations, and quota error remain green.

- [ ] **Step 5: Commit controller state inspection**

```bash
git add Sources/Nous/Services/VoiceCommandController.swift Tests/NousTests/VoiceCommandControllerTests.swift
git commit -m "feat: expose app state to voice mode"
```

---

### Task 5: Provide Live App Snapshot from `ContentView`

**Files:**
- Modify: `Sources/Nous/App/ContentView.swift`

- [ ] **Step 1: Wire the snapshot provider into `VoiceActionHandlers`**

In `configureVoiceHandlers(dependencies:)`, add this argument to the `VoiceActionHandlers` initializer after `openSettingsSection`:

```swift
appSnapshot: {
    voiceAppSnapshot(dependencies: dependencies)
}
```

The end of the initializer should look like:

```swift
openSettingsSection: { section in
    selectedSettingsSection = settingsSection(for: section)
    selectedTab = .settings
},
appSnapshot: {
    voiceAppSnapshot(dependencies: dependencies)
}
```

- [ ] **Step 2: Add snapshot helper methods**

Add these private helpers to `ContentView` near `settingsSection(for:)`:

```swift
private func voiceAppSnapshot(dependencies: AppDependencies) -> VoiceAppSnapshot {
    let projectId = dependencies.chatVM.currentNode?.projectId
        ?? selectedProjectId
        ?? dependencies.chatVM.defaultProjectId
    let projectName = projectId.flatMap { id in
        (try? dependencies.nodeStore.fetchProject(id: id))?.title
    }

    return VoiceAppSnapshot(
        currentTab: voiceNavigationTarget(for: selectedTab),
        settingsSection: selectedTab == .settings ? voiceSettingsSection(for: selectedSettingsSection) : nil,
        composerText: dependencies.chatVM.inputText,
        selectedProjectName: projectName,
        sidebarVisible: isSidebarVisible,
        scratchpadVisible: isScratchPadVisible,
        activeConversationTitle: dependencies.chatVM.currentNode?.title
    )
}

private func voiceNavigationTarget(for tab: MainTab) -> VoiceNavigationTarget {
    switch tab {
    case .chat: return .chat
    case .notes: return .notes
    case .galaxy: return .galaxy
    case .settings: return .settings
    }
}

private func voiceSettingsSection(for section: SettingsSection) -> VoiceSettingsSection {
    switch section {
    case .profile: return .profile
    case .general: return .general
    case .models: return .models
    case .memory: return .memory
    }
}
```

- [ ] **Step 3: Build the app**

Run:

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' -derivedDataPath .context/DerivedDataAppWideVoice build
```

Expected: build succeeds. If it fails because `fetchProject(id:)` throws or returns a different optional shape, adjust only the `projectName` expression to match the existing `NodeStore.fetchProject(id:)` signature.

- [ ] **Step 4: Commit ContentView snapshot wiring**

```bash
git add Sources/Nous/App/ContentView.swift
git commit -m "feat: provide voice app state snapshot"
```

---

### Task 6: Verify End-to-End Voice Control Behavior

**Files:**
- No new files unless a verification test exposes a bug.

- [ ] **Step 1: Run the focused voice test suites**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -derivedDataPath .context/DerivedDataAppWideVoice EXCLUDED_SOURCE_FILE_NAMES=SkillPayloadCodableTests.swift -only-testing:NousTests/VoiceActionRegistryTests -only-testing:NousTests/RealtimeVoiceSessionTests -only-testing:NousTests/VoiceCommandControllerTests
```

Expected: all selected voice tests pass with 0 failures.

- [ ] **Step 2: Run the app build**

Run:

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' -derivedDataPath .context/DerivedDataAppWideVoice build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run repository sanity checks**

Run:

```bash
git diff --check
find Sources/Nous -maxdepth 1 -name '*.swift' -print
```

Expected:

- `git diff --check` prints no output.
- `find Sources/Nous -maxdepth 1 -name '*.swift' -print` prints no source files in the root `Sources/Nous` directory.

- [ ] **Step 4: Commit final verification notes only if code changed during verification**

If no files changed during verification, do not create a commit. If a small bug fix was required, stage only the changed voice files and commit:

```bash
git add Sources/Nous/Models/Voice/VoiceModeModels.swift Sources/Nous/Services/VoiceActionRegistry.swift Sources/Nous/Services/RealtimeVoiceSession.swift Sources/Nous/Services/VoiceCommandController.swift Sources/Nous/App/ContentView.swift Tests/NousTests/VoiceActionRegistryTests.swift Tests/NousTests/RealtimeVoiceSessionTests.swift Tests/NousTests/VoiceCommandControllerTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "fix: stabilize app-wide voice control"
```

---

## Self-Review

**Spec coverage**

- Persistent one-click Voice Mode: covered by existing toggle behavior plus Task 6 focused verification.
- App-owned action registry: Task 1 and Task 2.
- `get_app_state`: Task 1, Task 4, and Task 5.
- Realtime tool declarations sourced from registry: Task 3.
- Safe direct actions and confirmation actions: Task 2 risk metadata and existing controller tests in Task 4.
- Settings navigation without voice disconnect: existing `VoiceCommandControllerTests/testOpenSettingsSectionKeepsActiveSession` remains in Task 4 test suite.
- No arbitrary mouse/system control: registry catalog in Task 2 contains no click, keyboard, AppleScript, shell, or Accessibility tools.

**Known test target constraint**

The full `NousTests` target currently includes unrelated untracked SkillPayload work. Use `EXCLUDED_SOURCE_FILE_NAMES=SkillPayloadCodableTests.swift` for the voice test commands in this plan, matching the current workspace state.

**Implementation boundary**

This plan deliberately does not add new app actions such as selecting arbitrary Galaxy nodes or searching notes. It creates the registry and state snapshot boundary first, then keeps the initial catalog behaviorally aligned with the actions already present in the app.
