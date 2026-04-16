# Clarification Trigger Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the clarification-trigger redesign from `docs/superpowers/specs/2026-04-16-clarification-trigger-design.md` — depth-test-driven behavior with hypothesis-loaded `<card>` output, `<defer/>` mechanism, and the four response channels — plus the Gemini 2.5 Pro model swap.

**Architecture:** Prompt-layer changes in `anchor.md` instruct the LLM to emit `<card>...</card>` or `<defer/>` control tags on specific conditions. A parser in `ChatViewModel` intercepts these tags post-stream and either (a) populates a new `Message.cardPayload` for the UI card, (b) suppresses the message entirely on `<defer/>`, or (c) renders as plain text. A new `CardView` SwiftUI component renders the card with stacked options and a fixed "写下你的想法" escape wired to focus the composer.

**Tech Stack:** Swift 5.9+, SwiftUI, XCTest, SQLite (existing `Database` wrapper), Gemini 2.5 Pro via REST.

**Landing order rationale:** App-layer lands before prompt rewrite. This way, when the prompt starts emitting `<card>` tags, the rendering and parsing are already in place — the user never sees raw XML.

---

## File Map

**Create:**
- `Sources/Nous/Views/CardView.swift` — card UI component
- `Sources/Nous/Services/ResponseTagParser.swift` — pure parser for `<card>` / `<defer/>` tags
- `Tests/NousTests/ResponseTagParserTests.swift`
- `Tests/NousTests/MessageCardPayloadTests.swift`
- `Tests/NousTests/NodeStoreCardPayloadTests.swift`

**Modify:**
- `Sources/Nous/Models/Message.swift` — add `CardPayload` struct + optional field
- `Sources/Nous/Services/NodeStore.swift:42-66` — schema + migration
- `Sources/Nous/Services/NodeStore.swift:218-247` — insert/fetch with cardPayload
- `Sources/Nous/ViewModels/ChatViewModel.swift:140-153` — parse tags after streaming
- `Sources/Nous/Views/ChatArea.swift:29-44` — render card inline; pass focus signal
- `Sources/Nous/Views/ChatComposer.swift:48-65` — expose external focus trigger
- `Sources/Nous/Resources/anchor.md` — core principle rewrite + new sections + example rewrites
- `Sources/Nous/Services/LLMService.swift:154` — model swap
- `Nous.xcodeproj/project.pbxproj` — register new files (done by Xcode or manual pbxproj edit)

---

## Task 1: Extend Message with CardPayload (TDD)

**Files:**
- Modify: `Sources/Nous/Models/Message.swift`
- Create: `Tests/NousTests/MessageCardPayloadTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/NousTests/MessageCardPayloadTests.swift`:

```swift
import XCTest
@testable import Nous

final class MessageCardPayloadTests: XCTestCase {
    func testCardPayloadRoundtripsThroughCodable() throws {
        let payload = CardPayload(
            framing: "你问我呢个背后...",
            options: ["已经决定咗", "Build 卡咗"]
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CardPayload.self, from: data)
        XCTAssertEqual(decoded.framing, "你问我呢个背后...")
        XCTAssertEqual(decoded.options, ["已经决定咗", "Build 卡咗"])
    }

    func testMessageWithoutCardPayloadIsNil() {
        let msg = Message(nodeId: UUID(), role: .assistant, content: "hello")
        XCTAssertNil(msg.cardPayload)
    }

    func testMessageWithCardPayloadRoundtripsThroughCodable() throws {
        let payload = CardPayload(framing: "f", options: ["a", "b"])
        let msg = Message(
            nodeId: UUID(),
            role: .assistant,
            content: "f",
            cardPayload: payload
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(decoded.cardPayload?.options, ["a", "b"])
    }

    func testMessageDecodingLegacyJsonWithoutCardPayloadSucceeds() throws {
        // Legacy JSON (no cardPayload field) must still decode.
        let legacyJSON = #"""
        {"id":"11111111-1111-1111-1111-111111111111","nodeId":"22222222-2222-2222-2222-222222222222","role":"assistant","content":"hi","timestamp":729876543.0}
        """#
        let data = Data(legacyJSON.utf8)
        let msg = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(msg.content, "hi")
        XCTAssertNil(msg.cardPayload)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' -only-testing:NousTests/MessageCardPayloadTests 2>&1 | tail -40`

Expected: build failure — `CardPayload` does not exist yet; `Message` init has no `cardPayload:` parameter.

- [ ] **Step 3: Write minimal implementation**

Replace the contents of `Sources/Nous/Models/Message.swift` with:

```swift
import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
}

struct CardPayload: Codable, Equatable {
    let framing: String
    let options: [String]
}

struct Message: Identifiable, Codable {
    let id: UUID
    let nodeId: UUID
    let role: MessageRole
    let content: String
    let timestamp: Date
    let cardPayload: CardPayload?

    init(
        id: UUID = UUID(),
        nodeId: UUID,
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        cardPayload: CardPayload? = nil
    ) {
        self.id = id
        self.nodeId = nodeId
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.cardPayload = cardPayload
    }
}
```

`CardPayload?` being optional + `Codable`'s default behavior means legacy JSON without the field still decodes.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' -only-testing:NousTests/MessageCardPayloadTests 2>&1 | tail -20`

Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Models/Message.swift Tests/NousTests/MessageCardPayloadTests.swift
git commit -m "feat: add CardPayload to Message model"
```

---

## Task 2: ResponseTagParser (TDD)

**Files:**
- Create: `Sources/Nous/Services/ResponseTagParser.swift`
- Create: `Tests/NousTests/ResponseTagParserTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/NousTests/ResponseTagParserTests.swift`:

```swift
import XCTest
@testable import Nous

final class ResponseTagParserTests: XCTestCase {
    func testPlainTextReturnsPlainResult() {
        let result = ResponseTagParser.parse("辛苦晒。")
        switch result {
        case .plain(let text): XCTAssertEqual(text, "辛苦晒。")
        default: XCTFail("expected .plain, got \(result)")
        }
    }

    func testDeferTagAloneReturnsDefer() {
        let result = ResponseTagParser.parse("<defer/>")
        if case .defer_ = result {} else { XCTFail("expected .defer_") }
    }

    func testDeferTagWithSurroundingWhitespaceReturnsDefer() {
        let result = ResponseTagParser.parse("  \n<defer/>\n  ")
        if case .defer_ = result {} else { XCTFail("expected .defer_") }
    }

    func testDeferTagWithExtraTextStripsTagReturnsPlain() {
        // Malformed: defer mixed with text. Strip tag, render remaining.
        let result = ResponseTagParser.parse("some text <defer/> more")
        switch result {
        case .plain(let text): XCTAssertEqual(text, "some text  more")
        default: XCTFail("expected .plain, got \(result)")
        }
    }

    func testCardWithTwoOptionsParses() {
        let response = """
        <card>
        <framing>你问我呢个背后...</framing>
        <option>已经决定咗</option>
        <option>Build 卡咗</option>
        </card>
        """
        let result = ResponseTagParser.parse(response)
        switch result {
        case .card(let payload):
            XCTAssertEqual(payload.framing, "你问我呢个背后...")
            XCTAssertEqual(payload.options, ["已经决定咗", "Build 卡咗"])
        default:
            XCTFail("expected .card, got \(result)")
        }
    }

    func testCardWithOneOptionParses() {
        let response = """
        <card><framing>f</framing><option>only</option></card>
        """
        let result = ResponseTagParser.parse(response)
        switch result {
        case .card(let payload):
            XCTAssertEqual(payload.framing, "f")
            XCTAssertEqual(payload.options, ["only"])
        default: XCTFail("expected .card")
        }
    }

    func testCardWithMissingFramingFallsBackToPlain() {
        let response = "<card><option>a</option></card>"
        let result = ResponseTagParser.parse(response)
        switch result {
        case .plain: break  // fallback acceptable
        case .card: break   // empty framing also acceptable as long as we don't crash
        default: XCTFail("unexpected .defer_")
        }
    }

    func testMalformedCardFallsBackToPlainText() {
        let response = "<card><framing>f</framing<option>broken"
        let result = ResponseTagParser.parse(response)
        switch result {
        case .plain(let text):
            XCTAssertTrue(text.contains("broken"))
        default:
            XCTFail("expected fallback to .plain for malformed card, got \(result)")
        }
    }

    func testMoreThanTwoOptionsAreAllParsed() {
        // Parser does not enforce max-2; that is the prompt's job.
        // Parser surfaces whatever options the LLM emits.
        let response = """
        <card><framing>f</framing><option>a</option><option>b</option><option>c</option></card>
        """
        let result = ResponseTagParser.parse(response)
        switch result {
        case .card(let payload):
            XCTAssertEqual(payload.options.count, 3)
        default: XCTFail("expected .card")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' -only-testing:NousTests/ResponseTagParserTests 2>&1 | tail -40`

Expected: build failure — `ResponseTagParser` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/Nous/Services/ResponseTagParser.swift`:

```swift
import Foundation

enum ParsedResponse {
    case plain(String)
    case card(CardPayload)
    case defer_
}

enum ResponseTagParser {
    static func parse(_ raw: String) -> ParsedResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Defer: response is exactly <defer/> (with any whitespace around).
        if trimmed == "<defer/>" {
            return .defer_
        }

        // Try to parse <card>...</card>.
        if let cardRange = trimmed.range(of: "<card>"),
           let cardEnd = trimmed.range(of: "</card>", range: cardRange.upperBound..<trimmed.endIndex) {
            let inner = String(trimmed[cardRange.upperBound..<cardEnd.lowerBound])
            if let payload = parseCardInner(inner) {
                return .card(payload)
            }
            // Malformed card → fall through to plain.
        }

        // Strip stray <defer/> from mixed content.
        let cleaned = trimmed.replacingOccurrences(of: "<defer/>", with: "")
        return .plain(cleaned)
    }

    private static func parseCardInner(_ inner: String) -> CardPayload? {
        let framing = firstMatch(pattern: "<framing>(.*?)</framing>", in: inner) ?? ""
        let options = allMatches(pattern: "<option>(.*?)</option>", in: inner)
        guard !options.isEmpty else { return nil }
        return CardPayload(framing: framing.trimmingCharacters(in: .whitespacesAndNewlines),
                           options: options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, range: range),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func allMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { m in
            guard m.numberOfRanges >= 2,
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' -only-testing:NousTests/ResponseTagParserTests 2>&1 | tail -20`

Expected: all 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/ResponseTagParser.swift Tests/NousTests/ResponseTagParserTests.swift
git commit -m "feat: add ResponseTagParser for <card> and <defer/> tags"
```

---

## Task 3: Database schema + migration for cardPayload (TDD)

**Files:**
- Modify: `Sources/Nous/Services/NodeStore.swift:42-66` (schema block)
- Modify: `Sources/Nous/Services/NodeStore.swift:218-247` (insert/fetch)
- Create: `Tests/NousTests/NodeStoreCardPayloadTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/NousTests/NodeStoreCardPayloadTests.swift`:

```swift
import XCTest
@testable import Nous

final class NodeStoreCardPayloadTests: XCTestCase {
    var nodeStore: NodeStore!

    override func setUp() {
        super.setUp()
        nodeStore = NodeStore(path: ":memory:")
        let node = NousNode(type: .conversation, title: "t")
        try? nodeStore.insertNode(node)
        self.nodeId = node.id
    }

    var nodeId: UUID!

    func testInsertAndFetchMessageWithoutCardPayload() throws {
        let msg = Message(nodeId: nodeId, role: .assistant, content: "hi")
        try nodeStore.insertMessage(msg)
        let fetched = try nodeStore.fetchMessages(nodeId: nodeId)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertNil(fetched.first?.cardPayload)
    }

    func testInsertAndFetchMessageWithCardPayload() throws {
        let payload = CardPayload(framing: "f", options: ["a", "b"])
        let msg = Message(
            nodeId: nodeId,
            role: .assistant,
            content: "f",
            cardPayload: payload
        )
        try nodeStore.insertMessage(msg)
        let fetched = try nodeStore.fetchMessages(nodeId: nodeId)
        XCTAssertEqual(fetched.first?.cardPayload?.framing, "f")
        XCTAssertEqual(fetched.first?.cardPayload?.options, ["a", "b"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' -only-testing:NousTests/NodeStoreCardPayloadTests 2>&1 | tail -40`

Expected: build failure or test failure — schema lacks `cardPayload` column; `insertMessage` does not bind it; `fetchMessages` does not read it.

- [ ] **Step 3: Update schema block**

In `Sources/Nous/Services/NodeStore.swift` replace the `CREATE TABLE IF NOT EXISTS messages` block (around line 42-49) with:

```swift
try db.exec("""
    CREATE TABLE IF NOT EXISTS messages (
        id           TEXT PRIMARY KEY,
        nodeId       TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
        role         TEXT NOT NULL,
        content      TEXT NOT NULL,
        timestamp    REAL NOT NULL,
        cardPayload  TEXT
    );
""")

// Migration for existing DBs that predate cardPayload.
// ADD COLUMN is a no-op if the column already exists, but SQLite throws
// on redefinition, so we guard by inspecting the schema.
let cardPayloadExists = try columnExists(table: "messages", column: "cardPayload")
if !cardPayloadExists {
    try db.exec("ALTER TABLE messages ADD COLUMN cardPayload TEXT;")
}
```

Add a helper method inside `NodeStore`:

```swift
private func columnExists(table: String, column: String) throws -> Bool {
    let stmt = try db.prepare("PRAGMA table_info(\(table));")
    while try stmt.step() {
        if stmt.text(at: 1) == column {
            return true
        }
    }
    return false
}
```

- [ ] **Step 4: Update insertMessage**

Replace the `insertMessage` function (around line 218-229) with:

```swift
func insertMessage(_ message: Message) throws {
    let stmt = try db.prepare("""
        INSERT INTO messages (id, nodeId, role, content, timestamp, cardPayload)
        VALUES (?, ?, ?, ?, ?, ?);
    """)
    try stmt.bind(message.id.uuidString, at: 1)
    try stmt.bind(message.nodeId.uuidString, at: 2)
    try stmt.bind(message.role.rawValue, at: 3)
    try stmt.bind(message.content, at: 4)
    try stmt.bind(message.timestamp.timeIntervalSince1970, at: 5)

    if let payload = message.cardPayload,
       let data = try? JSONEncoder().encode(payload),
       let json = String(data: data, encoding: .utf8) {
        try stmt.bind(json, at: 6)
    } else {
        try stmt.bind(nil as String?, at: 6)
    }

    try stmt.step()
}
```

- [ ] **Step 5: Update fetchMessages**

Replace the `fetchMessages` function (around line 231-247) with:

```swift
func fetchMessages(nodeId: UUID) throws -> [Message] {
    let stmt = try db.prepare("""
        SELECT id, nodeId, role, content, timestamp, cardPayload
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

        var cardPayload: CardPayload? = nil
        if let json = stmt.text(at: 5),
           let data = json.data(using: .utf8) {
            cardPayload = try? JSONDecoder().decode(CardPayload.self, from: data)
        }

        results.append(Message(
            id: id,
            nodeId: nId,
            role: role,
            content: content,
            timestamp: timestamp,
            cardPayload: cardPayload
        ))
    }
    return results
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' -only-testing:NousTests/NodeStoreCardPayloadTests 2>&1 | tail -20`

Also run existing NodeStore tests to verify no regression:
Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' -only-testing:NousTests/NodeStoreTests 2>&1 | tail -20`

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/Services/NodeStore.swift Tests/NousTests/NodeStoreCardPayloadTests.swift
git commit -m "feat: persist cardPayload column in messages table"
```

---

## Task 4: Wire ResponseTagParser into ChatViewModel

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift:140-153`

No new test file — this is plumbing between already-tested parser + already-tested persistence. Manual verification follows in later tasks.

- [ ] **Step 1: Modify send() to parse tags after streaming**

In `Sources/Nous/ViewModels/ChatViewModel.swift`, replace Step 8 + Step 9 (lines 139-153, roughly) with:

```swift
// Step 8: Stream response
do {
    let stream = try await llm.generate(messages: llmMessages, system: context)
    for try await chunk in stream {
        currentResponse += chunk
    }
} catch {
    currentResponse = "Error: \(error.localizedDescription)"
}

// Step 9: Parse tags and save assistant message
let parsed = ResponseTagParser.parse(currentResponse)
switch parsed {
case .defer_:
    // Nous chose silence. Do not append a message; keep composer active.
    currentResponse = ""
    // Early return — skip the rest of this turn's persistence + indexing.
    return

case .card(let payload):
    let assistantMessage = Message(
        nodeId: node.id,
        role: .assistant,
        content: payload.framing,
        cardPayload: payload
    )
    try? nodeStore.insertMessage(assistantMessage)
    messages.append(assistantMessage)

case .plain(let text):
    let assistantMessage = Message(
        nodeId: node.id,
        role: .assistant,
        content: text
    )
    try? nodeStore.insertMessage(assistantMessage)
    messages.append(assistantMessage)
}
```

Important: the `return` in the `.defer_` branch skips Step 10 (embedding + edge regeneration). That's intentional — there's no assistant content to index.

- [ ] **Step 2: Quick build check**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' 2>&1 | tail -20`

Expected: build succeeds. No runtime testing yet — that comes after UI work.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift
git commit -m "feat: dispatch <card> and <defer/> tags in ChatViewModel.send()"
```

---

## Task 5: CardView SwiftUI component

**Files:**
- Create: `Sources/Nous/Views/CardView.swift`

SwiftUI UI; no XCTest coverage. Verify manually via Xcode Previews and later integration.

- [ ] **Step 1: Create the component**

Create `Sources/Nous/Views/CardView.swift`:

```swift
import SwiftUI

struct CardView: View {
    let payload: CardPayload
    let onTapOption: (String) -> Void
    let onTapWriteOwn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !payload.framing.isEmpty {
                Text(payload.framing)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(AppColor.colaDarkText)
                    .lineSpacing(4)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }

            VStack(spacing: 8) {
                ForEach(payload.options, id: \.self) { option in
                    optionBubble(text: option) { onTapOption(option) }
                }
                optionBubble(text: "写下你的想法", isEscape: true) { onTapWriteOwn() }
            }
        }
        .padding(16)
        .background(AppColor.colaOrange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionBubble(text: String, isEscape: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isEscape
                                     ? AppColor.colaDarkText.opacity(0.55)
                                     : AppColor.colaDarkText)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(isEscape ? 0.45 : 0.78))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppColor.colaDarkText.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    CardView(
        payload: CardPayload(
            framing: "你问我呢个背后...",
            options: ["已经决定咗，想我 confirm", "Build 卡咗，想用 quit 推自己"]
        ),
        onTapOption: { print("option: \($0)") },
        onTapWriteOwn: { print("write own") }
    )
    .padding()
    .background(AppColor.colaBeige)
}
```

- [ ] **Step 2: Build and preview**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' 2>&1 | tail -20`

Expected: build succeeds.

Open `CardView.swift` in Xcode, enable Previews, visually verify: rounded container, two options stacked, "写下你的想法" at bottom with lighter style.

- [ ] **Step 3: Commit**

```bash
git add Sources/Nous/Views/CardView.swift
git commit -m "feat: add CardView component for clarification cards"
```

---

## Task 6: Integrate CardView into ChatArea + composer focus

**Files:**
- Modify: `Sources/Nous/Views/ChatComposer.swift:48-65`
- Modify: `Sources/Nous/Views/ChatArea.swift:29-44, 80-90`

- [ ] **Step 1: Add external focus trigger to ChatComposer**

In `Sources/Nous/Views/ChatComposer.swift`, add a `FocusState` and bridge it to an external trigger:

At the top of `ChatComposer` struct (after the existing stored properties):

```swift
@FocusState private var isTextFieldFocused: Bool

/// External trigger: flipping this toggles focus onto the text field.
/// Parent binds a Bool that it sets to `true` to request focus.
@Binding var focusRequest: Bool
```

Then on the `TextField` (around line 48-62), add the focus binding:

```swift
TextField("Ask Nous anything...", text: $text, axis: .vertical)
    .textFieldStyle(.plain)
    // ...existing modifiers...
    .focused($isTextFieldFocused)
    .onSubmit(onSend)
    .onChange(of: focusRequest) { _, newValue in
        if newValue {
            isTextFieldFocused = true
            focusRequest = false  // reset
        }
    }
```

- [ ] **Step 2: Render CardView in ChatArea message loop**

In `Sources/Nous/Views/ChatArea.swift`, add state for the focus trigger, and branch on `cardPayload` in the `ForEach`:

Add to state (near line 7):

```swift
@State private var composerFocusRequest: Bool = false
```

Replace the `ForEach(vm.messages) { msg in ... }` block (around line 31-33) with:

```swift
ForEach(vm.messages) { msg in
    if let payload = msg.cardPayload {
        CardView(
            payload: payload,
            onTapOption: { option in
                vm.inputText = option
                Task { await handleSend() }
            },
            onTapWriteOwn: {
                composerFocusRequest = true
            }
        )
    } else {
        MessageBubble(text: msg.content, isUser: msg.role == .user)
    }
}
```

Update the composer construction (around line 80-89) to pass the focus binding:

```swift
private var composer: some View {
    ChatComposer(
        text: $vm.inputText,
        attachments: attachedFiles,
        isGenerating: vm.isGenerating,
        onPickFiles: { isFileImporterPresented = true },
        onRemoveAttachment: removeAttachment,
        onSend: { Task { await handleSend() } },
        focusRequest: $composerFocusRequest
    )
}
```

- [ ] **Step 3: Build check**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' 2>&1 | tail -20`

Expected: build succeeds.

- [ ] **Step 4: Manual smoke test**

- Launch the app.
- Open an existing conversation (or start a new one).
- Manually insert a test card message into the DB, or temporarily hard-code a `Message` with `cardPayload` in the ViewModel to observe rendering.
- Verify: card renders with framing + 2 options + "写下你的想法".
- Tap an option → sends as user message, triggers LLM turn.
- Tap "写下你的想法" → composer gets focus.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/ChatArea.swift Sources/Nous/Views/ChatComposer.swift
git commit -m "feat: render CardView inline and wire composer focus"
```

---

## Task 7: Register new files in Xcode project

**Files:**
- Modify: `Nous.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add new files to Xcode target membership**

Open `Nous.xcodeproj` in Xcode. For each new file created above, verify target membership in the File Inspector:

- `Sources/Nous/Views/CardView.swift` → target: Nous (main app)
- `Sources/Nous/Services/ResponseTagParser.swift` → target: Nous (main app)
- `Tests/NousTests/MessageCardPayloadTests.swift` → target: NousTests
- `Tests/NousTests/ResponseTagParserTests.swift` → target: NousTests
- `Tests/NousTests/NodeStoreCardPayloadTests.swift` → target: NousTests

If Xcode has already auto-added them (it often does with "New File" dialog), confirm and skip.

- [ ] **Step 2: Verify full build + test suite**

Run: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' 2>&1 | tail -40`

Expected: all tests pass (including unrelated ones).

- [ ] **Step 3: Commit**

If `project.pbxproj` changed:

```bash
git add Nous.xcodeproj/project.pbxproj
git commit -m "chore: register clarification-trigger files in Xcode project"
```

If Xcode already tracked them earlier (e.g. via auto-detection during initial creation), this step may be a no-op.

---

## Task 8: Anchor rewrite + model swap

**Files:**
- Modify: `Sources/Nous/Resources/anchor.md`
- Modify: `Sources/Nous/Services/LLMService.swift:154`

This task has no automated tests — prompt behavior is LLM-dependent.

- [ ] **Step 1: Rewrite Core Principle #1 in anchor.md**

In `Sources/Nous/Resources/anchor.md`, find the `# CORE PRINCIPLES` section. Replace principle #1:

**From:**
```
1. 理解先于判断。问清楚先，再讲你点睇。唔好喺无足够上下文嘅时候出答案。
```

**To:**
```
1. 理解先于判断。但「问清楚」唔等如问 filler——冇 hypothesis 嘅问题唔值得出。宁愿直接回应佢讲嘅嘢，或者静一静等佢继续，都唔好问无重量嘅问题。
```

- [ ] **Step 2: Insert `# CLARIFICATION RULE` section**

Insert a new section between `# RESPONSE MODES` and `# CORE PRINCIPLES`:

```
# CLARIFICATION RULE

出卡（即系问 Alex 一条 clarifying question）之前，先过呢条 test：

    「如果 Alex 答『系』同答『唔系』，我下一句会唔会真系唔同？」

會唔同 → 呢张卡带住 hypothesis，值得出。
唔会唔同 → 你想问嘅系 filler。唔好问。

Filler 嘅典型样：「咩事呀？」「讲多啲？」「点解？」「系点样嘅？」
呢啲都系攞 fact，唔系睇穿。冇分量，拖时间。

真正嘅卡会指出 Alex 已经知但未讲嘅嘢。

当 depth test 失败，你必须 pick 其中一样，绝对唔准问：

(a) 直接回应佢讲嘅嘢
    就 surface 嗰层嘅内容讲返 something。
    适用：佢讲紧一个具体 situation / fact / decision。

(b) 讲试探性断言（hypothesis-as-statement，非问句）
    你有 guess 但唔想 interrogate，咁就讲出嚟等 Alex confirm / deny。
    适用：你睇到 subtext，但问出嚟会变 filler。
    例：「两个月忍到今日先讲，应该系顶到临界。」

(c) Defer —— 唔出声
    唔输出 message，等 Alex 继续输入。
    适用：佢嘅讯号系 ambient / 未讲完 / 想自己 unfold。
    输出方法：<defer/> tag。

呢三个 fallback 全部都 forbid 问号结尾。问号只留畀通过 depth test 嘅卡。

当 depth test 通过，有 hypothesis：
- ≥2 个真・唔同嘅 hypothesis（最多 2 个，而且系最接近嘅）→ 出 <card>
- 1 个 hypothesis → inline 讲（可以问句、可以断言，但要带分量）
- 5 个或以上 → 你谂多咗。Fall back 去 (a)。

注意：当 # EMOTION DETECTION 触发（Alex 讲紧情绪），嗰条 hard rule 行先。先回应情绪（1-2 句），然后先轮到 CLARIFICATION RULE。情绪阶段嘅「咩事？」「同我讲讲」唔当作 filler——佢哋系陪伴嘅一部分，唔係 interrogation。
```

- [ ] **Step 3: Insert `# OUTPUT FORMAT` section**

Insert immediately after `# CLARIFICATION RULE`:

```
# OUTPUT FORMAT

多数时候，output 系普通 plain text——一句广东话回应。

两种特殊情况：

## <card> —— 有 ≥2 个 hypothesis 时出

格式：

    <card>
    <framing>短 framing 句，最多一句。</framing>
    <option>第一个 hypothesis</option>
    <option>第二个 hypothesis</option>
    </card>

规则：
- <option> 数量：1 或 2（app 会硬加「写下你的想法」，你唔使 output）
- Option 文字：短、直接，一句完。唔用问号，用断言语气。
- Framing：一句 open door 嘅短句，例：「你问我呢个背后...」
- <card> block 之外唔好加其他 plain text。

## <defer/> —— 决定唔出声时

单独一个 tag，冇其他内容：

    <defer/>

App 收到 <defer/> 唔会 render message，保持 composer active，等 Alex 继续。
```

- [ ] **Step 4: Rewrite affected examples in `# EXAMPLES`**

**Replace the `做决定` block containing "我想 quit school 专心 build"**:

```
Alex: "我想quit school专心build"
Nous: <card>
      <framing>你嘅 F-1 系靠 school。你问我呢个背后...</framing>
      <option>已经决定咗，想我 confirm</option>
      <option>Build 卡咗，想用 quit 推自己 commit</option>
      </card>
```

**Replace the `情绪支持` block containing roommate 嘈**:

```
Alex: "我roommate每晚都好嘈，已经两个月，好崩溃"
Nous: "两个月。忍到今日先讲，应该系顶到临界。"
```

**Replace the `日常倾偈` block `Alex: "返到屋企了"`**:

```
Alex: "返到屋企了"
Nous: "辛苦晒。"
```

Leave other examples (`hi`, `first principles thinking`, `转 major loop`, `新 idea reading app`) unchanged for now — they are not in direct conflict with the new rule.

- [ ] **Step 5: Swap model to Gemini 2.5 Pro**

In `Sources/Nous/Services/LLMService.swift` line 154:

**From:**
```swift
var model: String = "gemini-2.5-flash"
```

**To:**
```swift
var model: String = "gemini-2.5-pro"
```

- [ ] **Step 6: Build**

Run: `xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' 2>&1 | tail -20`

Expected: build succeeds.

- [ ] **Step 7: Manual validation**

Launch the app. Run these scenarios, verifying Nous's behavior matches the spec:

| Input | Expected Behavior |
|---|---|
| `我想quit school专心build` | `<card>` with F-1 framing + 2 hypothesis options |
| `我 roommate 每晚都好嘈，已经两个月，好崩溃` | Inline observation (hypothesis-as-statement, no question mark) |
| `返到屋企了` | Short direct ack ("辛苦晒。" or similar), no question |
| `hi` | Short ack / greeting; no card |
| `今日好攰` | Either direct ack or tentative observation; no filler question |
| `我唔系好开心` | Emotion-first response (1-2 sentence empathy), then if a follow-up question, it should feel warm (emotion rule overrides) |

Record any regressions in a notes file (e.g. `.context/clarification-qa.md`) for iteration.

- [ ] **Step 8: Commit**

```bash
git add Sources/Nous/Resources/anchor.md Sources/Nous/Services/LLMService.swift
git commit -m "feat: activate clarification rule in anchor + upgrade to Gemini 2.5 Pro"
```

---

## Post-Implementation Validation

After all tasks complete, do a full scenario pass per the spec's Testing section:

- [ ] Run all unit tests: `xcodebuild test -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS'`
- [ ] Manual scenario pass — 8 canonical examples from anchor's `# EXAMPLES` section
- [ ] Depth test audit — across 20 varied prompts, count filler questions (target: 0)
- [ ] Verify `<defer/>` triggers in at least one ambient case
- [ ] Verify card renders, tap submits, write-own focuses composer
- [ ] Verify existing conversations (pre-migration) load without error

Watch for:
- Response too cold / too short (over-correction)
- Card firing too often (should be rare)
- `<defer/>` over-used as crutch
