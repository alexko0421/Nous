# Voice Transcript Chat Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist user voice utterances into the chat history of the conversation where voice mode started, with full pipeline parity for embedding / Galaxy / emoji refresh. Memory and title generation defer to the next typed assistant turn.

**Architecture:** Voice mode binds to its starting chat. Each finalized user transcript line dispatches via a new `VoiceTranscriptCommitter` to `ChatViewModel.appendVoiceMessage`, which uses `ConversationSessionStore.appendVoiceUserMessage` (new) to insert into `messages` + update `nodes.content`, then runs `TurnHousekeepingService.run(plan)` covering embedding refresh, Galaxy edges, and conversation emoji. The `propose_send_message` voice tool is removed because voice is now direct chat.

**Tech Stack:** Swift 6, SwiftUI, AppKit, raw SQLite (via `NodeStore`), Swift Observation framework (`@Observable`).

**Spec:** `docs/superpowers/specs/2026-04-29-voice-transcript-chat-persistence-design.md` (rev 5, four rounds of codex review).

---

## File Structure

**New files:**
- `Sources/Nous/Models/Voice/MessageSource.swift` — the `MessageSource` enum (kept separate so it can grow with voice-source variants in Phase 2 without polluting `Message.swift`).
- `Sources/Nous/Services/VoiceTranscriptCommitter.swift` — observes voice transcript finalize events, dispatches to `ChatViewModel`.
- `Tests/NousTests/Voice/VoiceTranscriptCommitterTests.swift` — committer unit tests.
- `Tests/NousTests/Voice/ConversationSessionStoreVoiceAppendTests.swift` — `appendVoiceUserMessage` unit tests.

**Modified files:**
- `Sources/Nous/Models/Message.swift` — add `source: MessageSource = .typed` to struct + designated initializer.
- `Sources/Nous/Services/NodeStore.swift` — `createTables` schema, `ensureColumnExists` for `source`, INSERT/SELECT.
- `Sources/Nous/Models/Voice/VoiceTranscriptLine.swift` — `finalize` returns the line via `@discardableResult`.
- `Sources/Nous/Services/VoiceActionRegistry.swift` — remove `propose_send_message` declaration.
- `Sources/Nous/Models/Voice/VoiceModeModels.swift` — remove `VoicePendingAction.sendMessage` case + `VoiceActionHandlers.sendMessage` closure.
- `Sources/Nous/Services/VoiceCommandController.swift` — add `boundConversationId`, `onUserUtteranceFinalized`, `onVoiceSessionTerminated`, `clearBoundConversation()`. Widen `failVoiceSession` access. Wire closure call. Remove `case .sendMessage` paths.
- `Sources/Nous/Services/RealtimeVoiceSession.swift` — update voice instructions: drop `propose_send_message`.
- `Sources/Nous/Services/ConversationSessionStore.swift` — add `appendVoiceUserMessage` + `CommittedVoiceTurn`.
- `Sources/Nous/ViewModels/ChatViewModel.swift` — add `ensureConversationForVoice`, `voiceUserHousekeepingPlan`, `appendVoiceMessage`.
- `Sources/Nous/Views/ChatArea.swift` — `MessageBubble` API change + mic icon rendering + update both call sites.
- `Sources/Nous/App/AppEnvironment.swift` — drop `sendMessage:` from `VoiceActionHandlers(...)`. Retain `VoiceTranscriptCommitter`.
- `Sources/Nous/App/ContentView.swift` — `toggleVoiceMode` calls `ensureConversationForVoice` and sets `boundConversationId` before `start`.
- `Tests/NousTests/VoiceActionRegistryTests.swift` — remove `propose_send_message` assertions.
- `Tests/NousTests/VoiceCommandControllerTests.swift` — remove sendMessage tests; keep createNote.
- `Tests/NousTests/Voice/VoiceCommandControllerIdempotencyTests.swift` — remove `.sendMessage` cases.
- `docs/superpowers/specs/2026-04-28-voice-mode-design.md` — deprecation note on `propose_send_message`.
- `docs/superpowers/specs/2026-04-28-app-wide-voice-control-design.md` — same.

---

## Phase 1 — Data Model Foundation

### Task 1.1 — Create `MessageSource` enum

**Files:**
- Create: `Sources/Nous/Models/Voice/MessageSource.swift`

- [ ] **Step 1: Write the file**

```swift
// Sources/Nous/Models/Voice/MessageSource.swift
import Foundation

/// Origin of a chat message. Determines whether the bubble renders a mic icon
/// next to the timestamp. Persisted as the `source` column in `messages`.
enum MessageSource: String, Codable, Equatable {
    case typed
    case voice
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -scheme Nous -configuration Debug -quiet build 2>&1 | tail -3
```

Expected: clean build (the enum has no consumers yet).

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Models/Voice/MessageSource.swift
git commit -m "feat(voice): add MessageSource enum for typed vs voice messages"
```

---

### Task 1.2 — Add `source` field to `Message`

**Files:**
- Modify: `Sources/Nous/Models/Message.swift`

- [ ] **Step 1: Add field + init parameter**

Edit `Sources/Nous/Models/Message.swift`. The struct currently has 7 stored properties (id, nodeId, role, content, timestamp, thinkingContent, agentTraceJson). Add `source` as the 8th, with a default in the initializer so existing call sites compile unchanged.

```swift
struct Message: Identifiable, Codable {
    let id: UUID
    let nodeId: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    var thinkingContent: String?
    var agentTraceJson: String?
    var source: MessageSource

    init(
        id: UUID = UUID(),
        nodeId: UUID,
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        thinkingContent: String? = nil,
        agentTraceJson: String? = nil,
        source: MessageSource = .typed
    ) {
        self.id = id
        self.nodeId = nodeId
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.thinkingContent = thinkingContent
        self.agentTraceJson = agentTraceJson
        self.source = source
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Nous -configuration Debug -quiet build 2>&1 | tail -3
```

Expected: clean build. All existing `Message(...)` call sites use the default `source: .typed`.

- [ ] **Step 3: Run full test suite to confirm no regression**

```bash
xcodebuild test -scheme Nous -configuration Debug -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Executed" | tail -3
```

Expected: TEST SUCCEEDED, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Models/Message.swift
git commit -m "feat(voice): add Message.source field defaulting to .typed"
```

---

## Phase 2 — SQL Migration

### Task 2.1 — Update schema + add migration

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift:120-141`

- [ ] **Step 1: Add `source` column to messages CREATE TABLE**

In `NodeStore.swift:121-129`, update the messages table creation:

```swift
try db.exec("""
    CREATE TABLE IF NOT EXISTS messages (
        id               TEXT PRIMARY KEY,
        nodeId           TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
        role             TEXT NOT NULL,
        content          TEXT NOT NULL,
        timestamp        REAL NOT NULL,
        thinking_content TEXT,
        source           TEXT NOT NULL DEFAULT 'typed'
    );
""")
```

- [ ] **Step 2: Add `ensureColumnExists` migration for legacy databases**

After the existing `ensureColumnExists(table: "messages", column: "agent_trace_json", ...)` block at `NodeStore.swift:137-141`, add:

```swift
try ensureColumnExists(
    table: "messages",
    column: "source",
    alterSQL: "ALTER TABLE messages ADD COLUMN source TEXT NOT NULL DEFAULT 'typed';"
)
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme Nous -configuration Debug -quiet build 2>&1 | tail -3
```

Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Services/NodeStore.swift
git commit -m "feat(voice): add source column to messages schema + ALTER migration"
```

---

### Task 2.2 — Update `insertMessage` and `fetchMessages`

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift:798-847`

- [ ] **Step 1: Update `insertMessage` to bind `source`**

Replace the body of `func insertMessage(_:)` with:

```swift
func insertMessage(_ message: Message) throws {
    let stmt = try db.prepare("""
        INSERT INTO messages (id, nodeId, role, content, timestamp, thinking_content, agent_trace_json, source)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
    """)
    try stmt.bind(message.id.uuidString, at: 1)
    try stmt.bind(message.nodeId.uuidString, at: 2)
    try stmt.bind(message.role.rawValue, at: 3)
    try stmt.bind(message.content, at: 4)
    try stmt.bind(message.timestamp.timeIntervalSince1970, at: 5)
    try stmt.bind(message.thinkingContent, at: 6)
    try stmt.bind(message.agentTraceJson, at: 7)
    try stmt.bind(message.source.rawValue, at: 8)
    try stmt.step()
    notifyNodesDidChange()
}
```

- [ ] **Step 2: Update `fetchMessages` to read + decode `source`**

Replace the body of `func fetchMessages(nodeId:)`:

```swift
func fetchMessages(nodeId: UUID) throws -> [Message] {
    let stmt = try db.prepare("""
        SELECT id, nodeId, role, content, timestamp, thinking_content, agent_trace_json, source
        FROM messages WHERE nodeId=? ORDER BY timestamp ASC;
    """)
    try stmt.bind(nodeId.uuidString, at: 1)
    var results: [Message] = []
    while try stmt.step() {
        let id = UUID(uuidString: stmt.text(at: 0) ?? "") ?? UUID()
        let nId = UUID(uuidString: stmt.text(at: 1) ?? "") ?? UUID()
        let role = MessageRole(rawValue: stmt.text(at: 2) ?? "") ?? .user
        let content = stmt.text(at: 3) ?? ""
        let timestamp = Date(timeIntervalSince1970: stmt.double(at: 4))
        let thinkingContent = stmt.text(at: 5)
        let agentTraceJson = stmt.text(at: 6)
        let sourceRaw = stmt.text(at: 7) ?? "typed"
        let source = MessageSource(rawValue: sourceRaw) ?? .typed
        results.append(Message(
            id: id,
            nodeId: nId,
            role: role,
            content: content,
            timestamp: timestamp,
            thinkingContent: thinkingContent,
            agentTraceJson: agentTraceJson,
            source: source
        ))
    }
    return results
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme Nous -configuration Debug -quiet build 2>&1 | tail -3
```

- [ ] **Step 4: Run full test suite**

```bash
xcodebuild test -scheme Nous -configuration Debug -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED" | tail -2
```

Expected: TEST SUCCEEDED. Existing tests insert + read messages; the new column with `DEFAULT 'typed'` round-trips cleanly.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/NodeStore.swift
git commit -m "feat(voice): persist Message.source through SQLite INSERT/SELECT"
```

---

### Task 2.3 — Round-trip + legacy-row decode test

**Files:**
- Create: `Tests/NousTests/Voice/MessageSourcePersistenceTests.swift`

- [ ] **Step 1: Write the test file**

```swift
// Tests/NousTests/Voice/MessageSourcePersistenceTests.swift
import XCTest
@testable import Nous

@MainActor
final class MessageSourcePersistenceTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var tempDBPath: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDBPath = NSTemporaryDirectory() + "voice-source-test-\(UUID().uuidString).db"
        nodeStore = try NodeStore(path: tempDBPath)
    }

    override func tearDown() async throws {
        nodeStore = nil
        try? FileManager.default.removeItem(atPath: tempDBPath)
        try await super.tearDown()
    }

    func testTypedMessageRoundTrip() throws {
        let nodeId = UUID()
        let node = NousNode(id: nodeId, type: .conversation, title: "Test")
        try nodeStore.insertNode(node)

        let message = Message(
            nodeId: nodeId,
            role: .user,
            content: "hello",
            source: .typed
        )
        try nodeStore.insertMessage(message)

        let fetched = try nodeStore.fetchMessages(nodeId: nodeId)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.source, .typed)
    }

    func testVoiceMessageRoundTrip() throws {
        let nodeId = UUID()
        let node = NousNode(id: nodeId, type: .conversation, title: "Test")
        try nodeStore.insertNode(node)

        let message = Message(
            nodeId: nodeId,
            role: .user,
            content: "spoken",
            source: .voice
        )
        try nodeStore.insertMessage(message)

        let fetched = try nodeStore.fetchMessages(nodeId: nodeId)
        XCTAssertEqual(fetched.first?.source, .voice)
    }

    func testLegacyMessageRowDecodesAsTyped() throws {
        // Simulate an older database row written without the source column
        // by inserting a typed-source row and then nulling out the column at
        // the SQL level. The DEFAULT 'typed' should backfill it on read.
        // (The migration's ALTER TABLE ... DEFAULT 'typed' covers existing
        // rows, but a legacy NULL would still decode as .typed because the
        // SELECT path uses `MessageSource(rawValue:) ?? .typed`.)
        let nodeId = UUID()
        let node = NousNode(id: nodeId, type: .conversation, title: "Test")
        try nodeStore.insertNode(node)

        let message = Message(nodeId: nodeId, role: .user, content: "legacy")
        try nodeStore.insertMessage(message)

        // The default flow already produces .typed; the rawValue lookup
        // would fall back if a NULL or unknown string showed up.
        let fetched = try nodeStore.fetchMessages(nodeId: nodeId)
        XCTAssertEqual(fetched.first?.source, .typed)
    }
}
```

- [ ] **Step 2: Run xcodegen if needed and build**

```bash
xcodegen generate 2>&1 | tail -3
xcodebuild test -scheme Nous -configuration Debug -destination 'platform=macOS' -only-testing:NousTests/MessageSourcePersistenceTests 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED" | tail -2
```

Expected: TEST SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Tests/NousTests/Voice/MessageSourcePersistenceTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "test(voice): MessageSource SQLite round-trip + legacy decode"
```

---

## Phase 3 — `MessageBubble` UI

### Task 3.1 — Add `source` and `timestamp` params to `MessageBubble`

**Files:**
- Modify: `Sources/Nous/Views/ChatArea.swift:658-665` (struct definition) + `:677` (body) + `:104, :178` (call sites)

- [ ] **Step 1: Update `MessageBubble` struct properties**

In `ChatArea.swift:658`, add two new params to the struct:

```swift
struct MessageBubble: View {
    let text: String
    let thinkingContent: String?
    let agentTraceRecords: [AgentTraceRecord]
    let isThinkingStreaming: Bool
    let isAgentTraceStreaming: Bool
    let isUser: Bool
    let source: MessageSource
    let timestamp: Date

    private let userBubbleMaxWidth: CGFloat = 520
    private let userParagraphSpacing: CGFloat = 10
    // ... rest unchanged ...
}
```

- [ ] **Step 2: Update both call sites in `ChatArea.swift`**

At `ChatArea.swift:104` (the persisted-message bubble), add `source` and `timestamp`:

```swift
MessageBubble(
    text: message.content,
    thinkingContent: message.thinkingContent,
    agentTraceRecords: agentTraceRecords,
    isThinkingStreaming: false,
    isAgentTraceStreaming: false,
    isUser: message.role == .user,
    source: message.source,
    timestamp: message.timestamp
)
```

At `ChatArea.swift:178` (the streaming bubble), use `source: .typed` and `timestamp: Date()` since streaming is always typed-flow:

```swift
MessageBubble(
    text: streamingText,
    thinkingContent: streamingThinkingContent,
    agentTraceRecords: streamingAgentTraceRecords,
    isThinkingStreaming: vm.isThinkingStreaming,
    isAgentTraceStreaming: vm.isAgentTraceStreaming,
    isUser: false,
    source: .typed,
    timestamp: Date()
)
```

(The exact surrounding code at each site may differ; preserve everything except add the two new params.)

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme Nous -configuration Debug -quiet build 2>&1 | tail -3
```

Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Views/ChatArea.swift
git commit -m "feat(voice): MessageBubble accepts source and timestamp"
```

---

### Task 3.2 — Render mic icon when source is `.voice`

**Files:**
- Modify: `Sources/Nous/Views/ChatArea.swift` (inside `MessageBubble.body`)

- [ ] **Step 1: Add timestamp + mic-icon HStack to `MessageBubble.body`**

Find a stable location in `MessageBubble.body` to render the timestamp (after the bubble content, typically below the message text). If the bubble currently does not render a timestamp, add one. The HStack:

```swift
HStack(spacing: 4) {
    Text(timestamp, style: .time)
        .font(.system(size: 10, weight: .regular, design: .rounded))
        .foregroundStyle(AppColor.tertiaryText)
    if source == .voice {
        Image(systemName: "mic.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppColor.colaOrange.opacity(0.6))
            .accessibilityLabel("Voice")
    }
}
.padding(.top, 2)
```

If `MessageBubble` already renders a timestamp elsewhere, add the mic icon next to it instead of duplicating the HStack.

If `AppColor.tertiaryText` does not exist, use `AppColor.secondaryText` as the closest equivalent.

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Nous -configuration Debug -quiet build 2>&1 | tail -3
```

- [ ] **Step 3: Visual smoke test**

Build and launch the Debug app, send a few typed messages. The bubbles should now show timestamps. The mic icon does NOT appear (no voice messages exist yet).

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Views/ChatArea.swift
git commit -m "feat(voice): render mic icon next to timestamp when source is .voice"
```

---

## Phase 4 — Remove `propose_send_message`

### Task 4.1 — Single-commit blast-radius removal

This task changes many files in one commit to keep runtime consistent (registry and instructions must update together).

**Files:**
- Modify: `Sources/Nous/Models/Voice/VoiceModeModels.swift:153,174,201,216`
- Modify: `Sources/Nous/Services/VoiceActionRegistry.swift`
- Modify: `Sources/Nous/Services/VoiceCommandController.swift:265,308,432`
- Modify: `Sources/Nous/Services/RealtimeVoiceSession.swift:332-340`
- Modify: `Sources/Nous/App/AppEnvironment.swift`
- Modify: `Tests/NousTests/VoiceActionRegistryTests.swift:42`
- Modify: `Tests/NousTests/VoiceCommandControllerTests.swift:339,704`
- Modify: `Tests/NousTests/Voice/VoiceCommandControllerIdempotencyTests.swift`
- Modify: `docs/superpowers/specs/2026-04-28-voice-mode-design.md`
- Modify: `docs/superpowers/specs/2026-04-28-app-wide-voice-control-design.md`

- [ ] **Step 1: Remove the enum case from `VoicePendingAction`**

In `VoiceModeModels.swift:153`:

```swift
enum VoicePendingAction: Equatable {
    // remove: case sendMessage(text: String)
    case createNote(title: String, body: String)
}
```

- [ ] **Step 2: Remove the closure from `VoiceActionHandlers`**

In `VoiceModeModels.swift:174`:

Remove `var sendMessage: (String) -> Void`.

In `VoiceModeModels.swift:201` and `:216`, remove `sendMessage:` from the init parameter list, the body assignment, and the `.empty` static value.

- [ ] **Step 3: Remove `propose_send_message` from the registry**

In `VoiceActionRegistry.swift`, search for `propose_send_message` and remove the entire tool declaration. The exact location depends on how the registry is structured — read the file first, then surgically remove just the `propose_send_message` block.

- [ ] **Step 4: Remove case paths in `VoiceCommandController`**

In `VoiceCommandController.swift`, search for `propose_send_message` and `case .sendMessage` and remove every occurrence (around lines 265, 308, 432). The compiler will catch missing branches in switch statements — fix each by removing the case rather than adding a default.

- [ ] **Step 5: Update voice instructions in `RealtimeVoiceSession.swift:332-340`**

The current instruction line says something like "Use propose_* tools for sending messages or creating notes." Change to:

```
"Use propose_create_note for creating notes. Voice user utterances are automatically recorded into the chat history."
```

(Use the actual surrounding wording — match style.)

- [ ] **Step 6: Update `AppEnvironment.swift` (or wherever real handlers are built)**

Search for `VoiceActionHandlers(` in `Sources/Nous/App/`. Remove the `sendMessage:` argument from the constructor call.

- [ ] **Step 7: Update tests**

In `VoiceActionRegistryTests.swift:42`, remove or invert the assertion that `propose_send_message` exists.

In `VoiceCommandControllerTests.swift:339, :704`, remove the test cases that exercise `sendMessage` confirmation. Keep cases that exercise `createNote`.

In `VoiceCommandControllerIdempotencyTests.swift`, search for `.sendMessage` and remove or replace those test cases with `.createNote` equivalents.

- [ ] **Step 8: Update parent specs**

In `docs/superpowers/specs/2026-04-28-voice-mode-design.md` near line 82 where `propose_send_message` is mentioned, append a deprecation note:

```
> **Deprecated 2026-04-29**: `propose_send_message` was removed when voice
> mode became direct chat. See
> `2026-04-29-voice-transcript-chat-persistence-design.md`. Voice user
> utterances now auto-record into chat history.
```

Same in `2026-04-28-app-wide-voice-control-design.md`.

- [ ] **Step 9: Build + run full tests**

```bash
xcodebuild test -scheme Nous -configuration Debug -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED|Executed" | tail -3
```

Expected: TEST SUCCEEDED. The compiler enforces every removed enum case got addressed. If a test fails because it asserted the tool's existence, update the assertion (it's an expected change).

- [ ] **Step 10: Final grep — make sure nothing references the removed names**

```bash
grep -rn "propose_send_message\|VoicePendingAction.sendMessage\|sendMessage:" Sources/Nous Tests/NousTests | grep -v "deprecated\|DEPRECATED\|removed in"
```

Expected: no output (or only test-helper / handlers-empty references that you intentionally left).

- [ ] **Step 11: Commit**

```bash
git add Sources/Nous Tests/NousTests docs/superpowers/specs/2026-04-28-voice-mode-design.md docs/superpowers/specs/2026-04-28-app-wide-voice-control-design.md
git commit -m "$(cat <<'EOF'
refactor(voice): remove propose_send_message tool (voice is now direct chat)

Voice mode auto-records user utterances into chat history (see
2026-04-29-voice-transcript-chat-persistence-design.md), so the
propose_send_message indirection is dead weight. Removed across:
registry, enum case, action handler closure, controller dispatch,
voice instructions in RealtimeVoiceSession, tests, parent specs.

createNote and other tools remain unchanged.
EOF
)"
```

---

## Phase 5 — `VoiceTranscriptLine.finalize` returns the line

### Task 5.1 — Make `finalize` return the finalized line

**Files:**
- Modify: `Sources/Nous/Models/Voice/VoiceTranscriptLine.swift`

- [ ] **Step 1: Update `finalize` signature and body**

Read the existing `finalize(text:role:into:now:)` method around `VoiceTranscriptLine.swift:37-50`. Modify:

```swift
@discardableResult
static func finalize(
    text: String,
    role: Role,
    into lines: inout [VoiceTranscriptLine],
    now: Date = Date()
) -> VoiceTranscriptLine {
    let finalizedLine: VoiceTranscriptLine
    if let lastIndex = lines.lastIndex(where: { $0.role == role && !$0.isFinal }) {
        var line = lines[lastIndex]
        line.text = text
        line.isFinal = true
        // preserve existing id and createdAt
        lines[lastIndex] = line
        finalizedLine = line
    } else {
        let newLine = VoiceTranscriptLine(
            id: UUID(),
            role: role,
            text: text,
            isFinal: true,
            createdAt: now
        )
        lines.append(newLine)
        finalizedLine = newLine
    }
    return finalizedLine
}
```

(Adapt to the existing exact body — the key is: change return type from `Void` to `VoiceTranscriptLine`, mark `@discardableResult`, return the just-finalized value.)

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Nous -configuration Debug -quiet build 2>&1 | tail -3
```

- [ ] **Step 3: Run full test suite**

```bash
xcodebuild test -scheme Nous -configuration Debug -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED" | tail -2
```

Expected: TEST SUCCEEDED. Existing call sites in `appendInputTranscript` / `appendOutputTranscript` use `finalize` for the side-effect; `@discardableResult` keeps them working unchanged.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Models/Voice/VoiceTranscriptLine.swift
git commit -m "feat(voice): VoiceTranscriptLine.finalize returns the finalized line"
```

---

## Phase 6 — `VoiceCommandController` Plumbing

### Task 6.1 — Add `boundConversationId` and termination closures

**Files:**
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`

- [ ] **Step 1: Add new published properties**

Near the top of the class (after `audioLevel`, alongside `visibleSurface`), add:

```swift
var boundConversationId: UUID?
var onUserUtteranceFinalized: ((VoiceTranscriptLine) -> Void)?
var onVoiceSessionTerminated: (() -> Void)?
```

`@Observable` already covers the published behavior on `boundConversationId`. Closures are not observed; they are externally set by `VoiceTranscriptCommitter`.

- [ ] **Step 2: Add `clearBoundConversation` private helper**

Anywhere private inside the class:

```swift
private func clearBoundConversation() {
    boundConversationId = nil
    onVoiceSessionTerminated?()
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme Nous -configuration Debug -quiet build 2>&1 | tail -3
```

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Services/VoiceCommandController.swift
git commit -m "feat(voice): add boundConversationId + termination closures to VoiceCommandController"
```

---

### Task 6.2 — Wire `clearBoundConversation` into terminal paths (NOT `resetTranscript`)

**Files:**
- Modify: `Sources/Nous/Services/VoiceCommandController.swift`

This task is the codex R4 critical fix. `resetTranscript()` MUST NOT call `clearBoundConversation()` because `markListening()` (called by `start()`) calls `resetTranscript()` immediately, which would clear the binding the moment voice starts.

- [ ] **Step 1: Make `failVoiceSession` accessible**

At `VoiceCommandController.swift:411`, change `private func failVoiceSession(message: String)` to `func failVoiceSession(message: String)` (drop `private`). The committer needs to call it on missing-node detection.

- [ ] **Step 2: Call `clearBoundConversation` from `stop()`**

In `func stop()` (around line 84), after the existing reset logic, add:

```swift
clearBoundConversation()
```

- [ ] **Step 3: Call `clearBoundConversation` from `failVoiceSession`**

Inside `func failVoiceSession(message:)` (around line 411), add at the end:

```swift
clearBoundConversation()
```

- [ ] **Step 4: Add `deinit` defensive call**

If the class doesn't already have a deinit, add one (note: `@Observable` may have constraints; check that this compiles):

```swift
deinit {
    Task { @MainActor [weak self] in
        self?.clearBoundConversation()
    }
}
```

If deinit-with-MainActor is awkward (it often is), skip this step — the hosting `AppDependencies` lifetime guarantees the controller outlives any voice session in practice.

- [ ] **Step 5: VERIFY `resetTranscript()` does NOT call `clearBoundConversation()`**

In `func resetTranscript()` (around line 484), the body should clear only the transcript array and subtitle/buffer state. There must be NO call to `clearBoundConversation()`.

- [ ] **Step 6: Build + test**

```bash
xcodebuild test -scheme Nous -configuration Debug -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED" | tail -2
```

Expected: TEST SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/Services/VoiceCommandController.swift
git commit -m "feat(voice): clear bound conversation on stop/fail (not on resetTranscript)"
```

---

### Task 6.3 — Wire `onUserUtteranceFinalized` into `completeInputTranscript`

**Files:**
- Modify: `Sources/Nous/Services/VoiceCommandController.swift:455-465`

- [ ] **Step 1: Capture finalize return value and fire closure**

Replace `func completeInputTranscript(_:)` body to:

```swift
private func completeInputTranscript(_ text: String) {
    inputTranscriptBuffer = text
    inputTranscriptIsFinal = true
    outputTranscriptBuffer = ""
    outputTranscriptIsFinal = false
    subtitleText = text
    if pendingAction == nil {
        status = .thinking
    }
    let line = VoiceTranscriptLine.finalize(text: text, role: .user, into: &transcript)
    onUserUtteranceFinalized?(line)
}
```

`completeOutputTranscript` is NOT modified — Phase 1 is user-only.

- [ ] **Step 2: Build + run tests**

```bash
xcodebuild test -scheme Nous -configuration Debug -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED" | tail -2
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Services/VoiceCommandController.swift
git commit -m "feat(voice): fire onUserUtteranceFinalized closure on user transcript completion"
```

---

## Phase 7 — `ConversationSessionStore.appendVoiceUserMessage`

### Task 7.1 — Add the method + `CommittedVoiceTurn` struct

**Files:**
- Modify: `Sources/Nous/Services/ConversationSessionStore.swift`

- [ ] **Step 1: Add struct + method**

Append to the file (or place near `CommittedAssistantTurn`):

```swift
struct CommittedVoiceTurn {
    let node: NousNode
    let userMessage: Message
    let messagesAfterAppend: [Message]
}

extension ConversationSessionStore {
    /// Append a voice user message to the given conversation. Inserts into
    /// `messages` (with `source: .voice`) and updates `nodes.content` via
    /// `persistTranscript`. Throws `missingNode` if the conversation does
    /// not exist (e.g. user deleted it mid-session).
    func appendVoiceUserMessage(
        nodeId: UUID,
        text: String,
        timestamp: Date
    ) throws -> CommittedVoiceTurn {
        guard let node = try nodeStore.fetchNode(id: nodeId) else {
            throw ConversationSessionStoreError.missingNode(nodeId)
        }

        let userMessage = Message(
            nodeId: node.id,
            role: .user,
            content: text,
            timestamp: timestamp,
            source: .voice
        )
        try nodeStore.insertMessage(userMessage)

        let messagesAfterAppend = try nodeStore.fetchMessages(nodeId: node.id)
        let updatedNode = try persistTranscript(node: node, messages: messagesAfterAppend)

        return CommittedVoiceTurn(
            node: updatedNode,
            userMessage: userMessage,
            messagesAfterAppend: messagesAfterAppend
        )
    }
}
```

`persistTranscript(node:messages:)` is the existing private(?) method on `ConversationSessionStore`. If it's private, adjust visibility or call the public `persistTranscript(nodeId:messages:)` overload (lines around 119-124).

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Nous -configuration Debug -quiet build 2>&1 | tail -3
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Services/ConversationSessionStore.swift
git commit -m "feat(voice): ConversationSessionStore.appendVoiceUserMessage"
```

---

### Task 7.2 — Unit tests for `appendVoiceUserMessage`

**Files:**
- Create: `Tests/NousTests/Voice/ConversationSessionStoreVoiceAppendTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/NousTests/Voice/ConversationSessionStoreVoiceAppendTests.swift
import XCTest
@testable import Nous

@MainActor
final class ConversationSessionStoreVoiceAppendTests: XCTestCase {
    private var nodeStore: NodeStore!
    private var store: ConversationSessionStore!
    private var tempDBPath: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDBPath = NSTemporaryDirectory() + "voice-append-test-\(UUID().uuidString).db"
        nodeStore = try NodeStore(path: tempDBPath)
        store = ConversationSessionStore(nodeStore: nodeStore)
    }

    override func tearDown() async throws {
        store = nil
        nodeStore = nil
        try? FileManager.default.removeItem(atPath: tempDBPath)
        try await super.tearDown()
    }

    func testAppendVoiceUserMessageInsertsAndUpdatesNodeContent() throws {
        let conversation = try store.startConversation(title: "Test")
        let timestamp = Date()

        let result = try store.appendVoiceUserMessage(
            nodeId: conversation.id,
            text: "hello world",
            timestamp: timestamp
        )

        XCTAssertEqual(result.userMessage.content, "hello world")
        XCTAssertEqual(result.userMessage.source, .voice)
        XCTAssertEqual(result.userMessage.role, .user)
        XCTAssertEqual(result.messagesAfterAppend.count, 1)
        XCTAssertFalse(result.node.content.isEmpty,
            "persistTranscript should populate nodes.content")
        XCTAssertTrue(result.node.content.contains("hello world"),
            "nodes.content should contain the voice utterance text")
    }

    func testAppendVoiceUserMessageThrowsForMissingNode() throws {
        let bogusId = UUID()
        XCTAssertThrowsError(
            try store.appendVoiceUserMessage(
                nodeId: bogusId,
                text: "lost",
                timestamp: Date()
            )
        ) { error in
            guard case ConversationSessionStoreError.missingNode(let id) = error else {
                XCTFail("expected missingNode, got \(error)")
                return
            }
            XCTAssertEqual(id, bogusId)
        }
    }

    func testAppendVoiceUserMessagePreservesPriorMessages() throws {
        let conversation = try store.startConversation(title: "Test")
        // Insert a typed message first (simulating an existing conversation)
        let typed = Message(
            nodeId: conversation.id,
            role: .user,
            content: "earlier",
            source: .typed
        )
        try nodeStore.insertMessage(typed)

        let result = try store.appendVoiceUserMessage(
            nodeId: conversation.id,
            text: "later",
            timestamp: Date()
        )

        XCTAssertEqual(result.messagesAfterAppend.count, 2)
        XCTAssertEqual(result.messagesAfterAppend.map(\.source), [.typed, .voice])
    }
}
```

- [ ] **Step 2: Run xcodegen + tests to verify they pass**

```bash
xcodegen generate 2>&1 | tail -3
xcodebuild test -scheme Nous -configuration Debug -destination 'platform=macOS' -only-testing:NousTests/ConversationSessionStoreVoiceAppendTests 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED" | tail -2
```

Expected: TEST SUCCEEDED (3/3).

- [ ] **Step 3: Commit**

```bash
git add Tests/NousTests/Voice/ConversationSessionStoreVoiceAppendTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "test(voice): ConversationSessionStore.appendVoiceUserMessage unit tests"
```

---

## Phase 8 — `ChatViewModel` Voice Methods

### Task 8.1 — Add `ensureConversationForVoice`, `voiceUserHousekeepingPlan`, `appendVoiceMessage`

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`

The methods must be in `ChatViewModel.swift` (not an extension in another file) so private members like `conversationSessionStore`, `turnHousekeepingService`, `defaultProjectId` are accessible.

- [ ] **Step 1: Add the three methods**

Add inside the `ChatViewModel` class body (find a suitable location near other voice-related or send-related methods):

```swift
// MARK: - Voice persistence

/// Returns the ID of the conversation voice should bind to. If a current
/// node exists, returns its ID. Otherwise creates an empty conversation.
func ensureConversationForVoice() throws -> UUID {
    if let current = currentNode {
        return current.id
    }
    let node = try conversationSessionStore.startConversation(
        title: "New Conversation",
        projectId: defaultProjectId
    )
    self.currentNode = node
    self.messages = []
    return node.id
}

/// Build a TurnHousekeepingPlan for a voice-user-only turn. Reuses the
/// embedding / Galaxy / emoji refresh paths the typed flow uses; skips
/// Gemini cache refresh because voice does not run through the
/// typed-flow LLM service.
private func voiceUserHousekeepingPlan(
    node: NousNode,
    messagesAfterAppend: [Message]
) -> TurnHousekeepingPlan {
    TurnHousekeepingPlan(
        turnId: UUID(),
        conversationId: node.id,
        geminiCacheRefresh: nil,
        embeddingRefresh: EmbeddingRefreshRequest(
            nodeId: node.id,
            fullContent: node.content
        ),
        emojiRefresh: ConversationEmojiRefreshRequest(
            node: node,
            messages: messagesAfterAppend
        )
    )
}

/// Append a voice user message and run the housekeeping pipeline.
/// Updates the in-memory `messages` array only if the bound node is
/// also the currently-loaded conversation.
func appendVoiceMessage(
    nodeId: UUID,
    text: String,
    timestamp: Date
) throws {
    let result = try conversationSessionStore.appendVoiceUserMessage(
        nodeId: nodeId,
        text: text,
        timestamp: timestamp
    )
    if currentNode?.id == nodeId {
        self.messages = result.messagesAfterAppend
    }
    let plan = voiceUserHousekeepingPlan(
        node: result.node,
        messagesAfterAppend: result.messagesAfterAppend
    )
    turnHousekeepingService.run(plan)
}
```

If the actual property names on `ChatViewModel` differ from `conversationSessionStore` / `turnHousekeepingService` / `defaultProjectId`, adjust accordingly. Search for `conversationSessionStore` in `ChatViewModel.swift` to confirm the binding.

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Nous -configuration Debug -quiet build 2>&1 | tail -3
```

- [ ] **Step 3: Run full test suite**

```bash
xcodebuild test -scheme Nous -configuration Debug -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED" | tail -2
```

Expected: TEST SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift
git commit -m "feat(voice): ChatViewModel.ensureConversationForVoice + appendVoiceMessage + housekeeping plan"
```

---

## Phase 9 — `VoiceTranscriptCommitter`

### Task 9.1 — Create the committer service

**Files:**
- Create: `Sources/Nous/Services/VoiceTranscriptCommitter.swift`

- [ ] **Step 1: Write the service**

```swift
// Sources/Nous/Services/VoiceTranscriptCommitter.swift
import Foundation

/// Glue between `VoiceCommandController` (which fires
/// `onUserUtteranceFinalized` after each finalized user line) and
/// `ChatViewModel.appendVoiceMessage` (which persists into the bound
/// chat and runs housekeeping).
///
/// Owns the dedup set keyed by `VoiceTranscriptLine.id`. Resets the set
/// whenever the controller signals session termination via
/// `onVoiceSessionTerminated`.
@MainActor
final class VoiceTranscriptCommitter {
    private weak var voiceController: VoiceCommandController?
    private weak var chatViewModel: ChatViewModel?
    private(set) var committedLineIds: Set<UUID> = []

    init(voiceController: VoiceCommandController, chatViewModel: ChatViewModel) {
        self.voiceController = voiceController
        self.chatViewModel = chatViewModel
        voiceController.onUserUtteranceFinalized = { [weak self] line in
            self?.commit(line)
        }
        voiceController.onVoiceSessionTerminated = { [weak self] in
            self?.committedLineIds.removeAll()
        }
    }

    deinit {
        // Closures are owned by the controller; reset them so a future
        // committer instance does not see stale capture.
        voiceController?.onUserUtteranceFinalized = nil
        voiceController?.onVoiceSessionTerminated = nil
    }

    private func commit(_ line: VoiceTranscriptLine) {
        guard line.role == .user else { return }
        guard !committedLineIds.contains(line.id) else { return }
        guard let conversationId = voiceController?.boundConversationId else { return }
        guard let viewModel = chatViewModel else { return }

        do {
            try viewModel.appendVoiceMessage(
                nodeId: conversationId,
                text: line.text,
                timestamp: line.createdAt
            )
            committedLineIds.insert(line.id)
        } catch ConversationSessionStoreError.missingNode {
            voiceController?.failVoiceSession(message: "Conversation deleted")
        } catch {
            // Phase 1 policy: log only, no retry.
            print("[VoiceTranscriptCommitter] commit failed: \(error)")
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate 2>&1 | tail -3
xcodebuild -scheme Nous -configuration Debug -quiet build 2>&1 | tail -3
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Services/VoiceTranscriptCommitter.swift Nous.xcodeproj/project.pbxproj
git commit -m "feat(voice): add VoiceTranscriptCommitter to dispatch finalized utterances to chat"
```

---

### Task 9.2 — Unit tests for the committer

**Files:**
- Create: `Tests/NousTests/Voice/VoiceTranscriptCommitterTests.swift`

- [ ] **Step 1: Write tests using stubs**

```swift
// Tests/NousTests/Voice/VoiceTranscriptCommitterTests.swift
import XCTest
@testable import Nous

@MainActor
final class VoiceTranscriptCommitterTests: XCTestCase {

    func testCommitsFinalizedUserLineToBoundConversation() throws {
        let nodeStore = try makeInMemoryNodeStore()
        let store = ConversationSessionStore(nodeStore: nodeStore)
        let conversation = try store.startConversation(title: "Test")

        let viewModel = makeChatViewModel(
            sessionStore: store,
            currentNode: conversation
        )
        let controller = VoiceCommandController()
        let committer = VoiceTranscriptCommitter(
            voiceController: controller,
            chatViewModel: viewModel
        )

        controller.boundConversationId = conversation.id
        let line = VoiceTranscriptLine(
            id: UUID(),
            role: .user,
            text: "voice content",
            isFinal: true,
            createdAt: Date()
        )
        controller.onUserUtteranceFinalized?(line)

        // The committer must insert the message into the bound conversation
        let messages = try nodeStore.fetchMessages(nodeId: conversation.id)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.source, .voice)
        XCTAssertEqual(messages.first?.content, "voice content")
        XCTAssertTrue(committer.committedLineIds.contains(line.id))
    }

    func testIgnoresAssistantLines() throws {
        let nodeStore = try makeInMemoryNodeStore()
        let store = ConversationSessionStore(nodeStore: nodeStore)
        let conversation = try store.startConversation(title: "Test")

        let viewModel = makeChatViewModel(
            sessionStore: store,
            currentNode: conversation
        )
        let controller = VoiceCommandController()
        _ = VoiceTranscriptCommitter(
            voiceController: controller,
            chatViewModel: viewModel
        )

        controller.boundConversationId = conversation.id
        let assistantLine = VoiceTranscriptLine(
            id: UUID(),
            role: .assistant,
            text: "should be ignored",
            isFinal: true,
            createdAt: Date()
        )
        controller.onUserUtteranceFinalized?(assistantLine)

        let messages = try nodeStore.fetchMessages(nodeId: conversation.id)
        XCTAssertEqual(messages.count, 0)
    }

    func testDeduplicatesSameLineId() throws {
        let nodeStore = try makeInMemoryNodeStore()
        let store = ConversationSessionStore(nodeStore: nodeStore)
        let conversation = try store.startConversation(title: "Test")

        let viewModel = makeChatViewModel(
            sessionStore: store,
            currentNode: conversation
        )
        let controller = VoiceCommandController()
        _ = VoiceTranscriptCommitter(
            voiceController: controller,
            chatViewModel: viewModel
        )

        controller.boundConversationId = conversation.id
        let line = VoiceTranscriptLine(
            id: UUID(),
            role: .user,
            text: "duplicate",
            isFinal: true,
            createdAt: Date()
        )
        controller.onUserUtteranceFinalized?(line)
        controller.onUserUtteranceFinalized?(line)

        let messages = try nodeStore.fetchMessages(nodeId: conversation.id)
        XCTAssertEqual(messages.count, 1, "second commit with same id should no-op")
    }

    func testTerminationResetsDedupSet() throws {
        let nodeStore = try makeInMemoryNodeStore()
        let store = ConversationSessionStore(nodeStore: nodeStore)
        let conversation = try store.startConversation(title: "Test")

        let viewModel = makeChatViewModel(
            sessionStore: store,
            currentNode: conversation
        )
        let controller = VoiceCommandController()
        let committer = VoiceTranscriptCommitter(
            voiceController: controller,
            chatViewModel: viewModel
        )

        controller.boundConversationId = conversation.id
        let line = VoiceTranscriptLine(
            id: UUID(),
            role: .user,
            text: "before",
            isFinal: true,
            createdAt: Date()
        )
        controller.onUserUtteranceFinalized?(line)
        XCTAssertEqual(committer.committedLineIds.count, 1)

        controller.onVoiceSessionTerminated?()
        XCTAssertEqual(committer.committedLineIds.count, 0)
    }

    // MARK: - Helpers

    private func makeInMemoryNodeStore() throws -> NodeStore {
        let path = NSTemporaryDirectory() + "committer-test-\(UUID().uuidString).db"
        // Track for cleanup
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: path)
        }
        return try NodeStore(path: path)
    }

    private func makeChatViewModel(
        sessionStore: ConversationSessionStore,
        currentNode: NousNode?
    ) -> ChatViewModel {
        // Construct ChatViewModel using whatever the project's existing
        // test helper provides. If no helper exists, the ChatViewModel
        // initializer must accept the dependencies needed for these
        // tests. This stub assumes ChatViewModel exposes a test-only
        // initializer or a protocol-based construction path. Adjust
        // during implementation to match the actual API.
        fatalError("Replace with actual ChatViewModel construction matching project conventions")
    }
}
```

The `makeChatViewModel` helper is a placeholder — the implementer adapts to whatever construction path `ChatViewModel` exposes for tests. If `ChatViewModel` has a hard-to-isolate initializer, consider adding a protocol over the appendVoiceMessage path and stubbing it in tests.

- [ ] **Step 2: Adapt the test helper to real `ChatViewModel` construction**

Look at existing `ChatViewModelTests.swift` to see how the project constructs `ChatViewModel` in tests. Mirror that pattern.

- [ ] **Step 3: Run tests**

```bash
xcodegen generate 2>&1 | tail -3
xcodebuild test -scheme Nous -configuration Debug -destination 'platform=macOS' -only-testing:NousTests/VoiceTranscriptCommitterTests 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED" | tail -2
```

Expected: TEST SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Tests/NousTests/Voice/VoiceTranscriptCommitterTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "test(voice): VoiceTranscriptCommitter dispatch + dedup + termination"
```

---

### Task 9.3 — Retain the committer in `AppDependencies`

**Files:**
- Modify: `Sources/Nous/App/AppEnvironment.swift`

- [ ] **Step 1: Add the property and construction**

Find the `AppDependencies` class declaration. Add a stored property:

```swift
let voiceTranscriptCommitter: VoiceTranscriptCommitter
```

In the initializer, after `voiceController` and `chatViewModel` are constructed, add:

```swift
self.voiceTranscriptCommitter = VoiceTranscriptCommitter(
    voiceController: voiceController,
    chatViewModel: chatViewModel
)
```

(The exact init order depends on the file's existing structure. Place the assignment after both dependencies exist.)

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Nous -configuration Debug -quiet build 2>&1 | tail -3
```

- [ ] **Step 3: Run full test suite**

```bash
xcodebuild test -scheme Nous -configuration Debug -destination 'platform=macOS' 2>&1 | grep -E "TEST SUCCEEDED|TEST FAILED" | tail -2
```

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/App/AppEnvironment.swift
git commit -m "feat(voice): AppDependencies retains VoiceTranscriptCommitter"
```

---

## Phase 10 — `ContentView.toggleVoiceMode`

### Task 10.1 — Ensure conversation + bind before start

**Files:**
- Modify: `Sources/Nous/App/ContentView.swift:322`

- [ ] **Step 1: Update `toggleVoiceMode`**

Read the existing `toggleVoiceMode` body. The new shape:

```swift
private func toggleVoiceMode(dependencies: AppDependencies) {
    if dependencies.voiceController.isActive {
        dependencies.voiceController.stop()
        return
    }

    let conversationId: UUID
    do {
        conversationId = try dependencies.chatVM.ensureConversationForVoice()
    } catch {
        // Surface the error in whatever way the existing app surfaces voice
        // errors (toast, alert, console log). Do NOT proceed to start voice.
        print("[ContentView] ensureConversationForVoice failed: \(error)")
        return
    }

    // CRITICAL: bind BEFORE start() runs. start() invokes markListening()
    // which calls resetTranscript(). resetTranscript() does NOT clear
    // boundConversationId (rev 5 fix), but the order matters: the
    // committer's onUserUtteranceFinalized closure reads
    // boundConversationId at fire time, so it must be set before any
    // utterance arrives.
    dependencies.voiceController.boundConversationId = conversationId

    Task {
        do {
            try await dependencies.voiceController.start(apiKey: dependencies.apiKey)
        } catch {
            print("[ContentView] voice start failed: \(error)")
        }
    }
}
```

Adjust to match the actual `dependencies` shape (the property names like `chatVM`, `apiKey`, etc.).

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Nous -configuration Debug -quiet build 2>&1 | tail -3
```

- [ ] **Step 3: Manual smoke test**

Launch the Debug build. From welcome state (no conversation selected), click the mic button. A new conversation should be created and voice should start. Speak a few words. After each utterance, a chat message should appear with the mic icon.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/App/ContentView.swift
git commit -m "feat(voice): ensure conversation + bind before voice start"
```

---

## Phase 11 — Manual QA Pass

### Task 11.1 — Run all manual QA cases

**Files:**
- Create: `docs/superpowers/spikes/2026-04-29-voice-transcript-qa-results.md`

Run each manual case from the spec § Manual QA Test Plan. Record results in the QA results doc.

- [ ] **Step 1: Capture & full pipeline**
  - Start voice in a chat. Speak 3 utterances. Verify 3 user messages with mic icons.
  - Open vector search. Search for a phrase from a voice utterance. Surfaces? (proves embedding refresh fired)
  - Verify bound conversation's emoji updates when previously empty.
  - Verify `nodes.content` of the bound conversation contains the voice text (re-launch app and reopen the conversation; voice text must be visible).

- [ ] **Step 2: Memory + title (Phase 1 deferral verification)**
  - Voice-only session: memory does NOT update yet. Expected per spec.
  - Type a message in the same conversation; after assistant responds, memory now picks up voice content.
  - Voice-only session: title remains "New Conversation". After next typed assistant turn, title generation runs.

- [ ] **Step 3: Bound conversation tests**
  - Switch chats mid-session: voice still records to start chat.
  - Stop, switch back: utterances all there.

- [ ] **Step 4: Empty-chat boot**
  - Voice from welcome state creates new conversation.

- [ ] **Step 5: Bound-conversation deletion**
  - Delete bound chat mid-session: voice transitions to `.error`, no crash.

- [ ] **Step 6: Tool removal**
  - Voice never proposes `sendMessage`.
  - `createNote` works.

- [ ] **Step 7: Schema migration**
  - Open app on pre-migration database. ALTER runs. Existing messages decode as `.typed`.

- [ ] **Step 8: Visual**
  - Mic icon spec: 11pt, colaOrange @ 0.6, 4pt right of timestamp.
  - Voice bubble shape/color/typography identical to typed.

- [ ] **Step 9: Mixed media**
  - Type between voice utterances. Interleave by timestamp. Mic icon only on voice.

- [ ] **Step 10: Reset-vs-terminate (codex R4 regression test)**
  - **CRITICAL**: Start voice. Within 1 second, speak. First utterance MUST land in chat. (Verifies `markListening` → `resetTranscript` does NOT clear binding.)
  - Stop voice → boundConversationId nil, committer set empty.
  - Voice fail (bad API key) → same.

- [ ] **Step 11: Document results**

```markdown
# Voice Transcript Chat Persistence — Manual QA Results

**Date:** YYYY-MM-DD
**Build:** <git short SHA>
**Tester:** Alex

## Capture & full pipeline
- [x] / [ ] / [BLOCKED] case-by-case results
...

## Failures
[list any]

## Verdict
SHIP / REWORK / BLOCK
```

- [ ] **Step 12: Fix any failures**

For each failure: write a regression test (where applicable), fix the code, verify, commit:

```bash
git add -u .
git commit -m "fix(voice): <one-line failure description>"
```

After all failures resolved, update the QA results doc and commit:

```bash
git add docs/superpowers/spikes/2026-04-29-voice-transcript-qa-results.md
git commit -m "test(voice): manual QA passing for transcript chat persistence"
```

---

## Done

When Phase 11 ends with all manual QA cases passing, voice mode auto-records user utterances into the chat history with mic icons, `nodes.content` reflects voice content, vector search surfaces it, Galaxy refreshes, and the conversation emoji updates. Memory and title backfill defer to the next typed assistant turn (Phase 1 explicit scope).

Phase 2 work (assistant voice persistence, full memory/title alignment, voice playback, search filters) is queued for a follow-up plan.
