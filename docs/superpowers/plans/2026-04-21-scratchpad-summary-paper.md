# ScratchPad Summary → White-Paper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `ScratchPadPanel` into a document-style "white paper" that loads the latest LLM-generated summary of the current chat, lets the user edit markdown, and exports to `.md` — driven by a `<summary>…</summary>` tag Nous emits when asked.

**Architecture:**
- A new `ScratchPadStore` (Services) owns summary + panel content state with dirty-vs-base semantics, backed by `UserDefaults`.
- `ClarificationCardParser` gains `extractSummary(from:)` and a `strippingSummaryTags` step inside its existing `parse(_:)` pipeline, so the chat bubble keeps rendering summary text inline (tag stripped).
- `ChatViewModel` pushes each finished assistant message into the store, which decides whether to update `latestSummary`.
- A new stable prompt layer `summaryOutputPolicy` instructs the model to wrap summary output in `<summary>` with the required markdown structure; the layer is cached alongside `anchor` / `coreSafetyPolicy`.
- `ScratchPadPanel` becomes a 420pt white-paper view (serif body, warm off-white background, subtle shadow) with a header (download button, Write/Preview toggle, close) and an `.alert` for overwrite protection; `NSSavePanel` handles export.

**Tech Stack:** SwiftUI on macOS 26, Swift 5.9+, XCTest via `./scripts/test_nous.sh`, existing `@AppStorage` + new `UserDefaults`-backed store.

**Spec:** `docs/superpowers/specs/2026-04-21-scratchpad-summary-paper-design.md`

**File map (what this plan will create / modify):**

| Path | Change | Responsibility |
|---|---|---|
| `Sources/Nous/Services/ClarificationCardParser.swift` | Modify | Add `extractSummary(from:)` + strip `<summary>` tags (content-preserving) in `parse(_:)` display pipeline. |
| `Tests/NousTests/ClarificationCardParserTests.swift` | Modify | Add summary-extract / tag-strip / multi-tag / malformed cases. |
| `Sources/Nous/Models/ScratchSummary.swift` | **Create** | `ScratchSummary` value type (markdown + generatedAt + sourceMessageId). |
| `Sources/Nous/Services/ScratchPadStore.swift` | **Create** | `@Observable` store owning `latestSummary`, `currentContent`, `baseSnapshot`, `contentBaseGeneratedAt`, `pendingOverwrite`; load / accept / reject / download-complete logic. |
| `Tests/NousTests/ScratchPadStoreTests.swift` | **Create** | Eight behavioral cases per spec §10. |
| `Sources/Nous/ViewModels/ChatViewModel.swift` | Modify | Call `scratchPadStore.ingestAssistantMessage(...)` at both finish sites; add `summaryOutputPolicy` stable layer; update governance trace layer name list. |
| `Tests/NousTests/ChatViewModelTests.swift` | Modify | New `testIngestsSummaryFromAssistantReply()` + `testGovernanceTraceIncludesSummaryPolicyLayer()`. |
| `Sources/Nous/App/AppEnvironment.swift` | Modify | Build + wire `ScratchPadStore` into `AppDependencies`; inject into `ChatViewModel` init. |
| `Sources/Nous/App/ContentView.swift` | Modify | Pass store to `ScratchPadPanel`; rely on existing `isScratchPadVisible` binding. |
| `Sources/Nous/Views/ScratchPadPanel.swift` | Modify | 420pt width; warm-white paper surface with shadow + serif body; header (download/toggle/close); empty state; load logic via `onAppear` + `onChange(of:)`; overwrite alert; download via `NSSavePanel`. |
| `Sources/Nous/Views/FilenameSlug.swift` | **Create** | Pure `filenameSlug(fromMarkdown:fallbackDate:)` helper. |
| `Tests/NousTests/FilenameSlugTests.swift` | **Create** | Heading slug / CJK / disallowed chars / empty / 60-char boundary. |
| `project.yml` | Modify (if needed) | Re-run `xcodegen` after adding new source / test files so they enter the build. |

---

## Task 1: Parser extension — extract summary + strip tags in display pipeline

**Files:**
- Modify: `Sources/Nous/Services/ClarificationCardParser.swift`
- Test: `Tests/NousTests/ClarificationCardParserTests.swift`

- [ ] **Step 1: Add failing tests for summary extraction**

Append these tests to `Tests/NousTests/ClarificationCardParserTests.swift` (inside the existing `final class ClarificationCardParserTests: XCTestCase`):

```swift
func testExtractSummaryReturnsInnerMarkdownWhenWellFormed() {
    let raw = """
    整好了，睇下右边。
    <summary>
    # 关于 Notion 产品方向

    ## 问题
    Alex 想搞清楚 Notion 该不该加 AI agent。

    ## 思考
    倾咗 retention vs differentiation。

    ## 结论
    暂时唔做。

    ## 下一步
    - 观察 Coda 三个月
    </summary>
    多谢！
    """

    let extracted = ClarificationCardParser.extractSummary(from: raw)
    XCTAssertNotNil(extracted)
    XCTAssertTrue(extracted!.hasPrefix("# 关于 Notion 产品方向"))
    XCTAssertTrue(extracted!.contains("## 下一步"))
}

func testExtractSummaryReturnsNilWhenNoTag() {
    XCTAssertNil(ClarificationCardParser.extractSummary(from: "No summary here."))
}

func testExtractSummaryReturnsNilWhenUnclosed() {
    let raw = "<summary>\n# Title\nSome text without closing tag"
    XCTAssertNil(ClarificationCardParser.extractSummary(from: raw))
}

func testExtractSummaryReturnsNilWhenEmptyBody() {
    XCTAssertNil(ClarificationCardParser.extractSummary(from: "before <summary>   </summary> after"))
}

func testExtractSummaryPrefersFirstPair() {
    let raw = """
    <summary># First</summary>
    <summary># Second</summary>
    """
    let extracted = ClarificationCardParser.extractSummary(from: raw)
    XCTAssertEqual(extracted, "# First")
}

func testParseStripsSummaryTagsButPreservesInnerContentInDisplayText() {
    let raw = """
    整好了。
    <summary>
    # Hello

    世界
    </summary>
    """
    let parsed = ClarificationCardParser.parse(raw)
    XCTAssertFalse(parsed.displayText.contains("<summary>"))
    XCTAssertFalse(parsed.displayText.contains("</summary>"))
    XCTAssertTrue(parsed.displayText.contains("# Hello"))
    XCTAssertTrue(parsed.displayText.contains("世界"))
    XCTAssertTrue(parsed.displayText.contains("整好了"))
}
```

- [ ] **Step 2: Run tests, verify failure**

```bash
./scripts/test_nous.sh -only-testing:NousTests/ClarificationCardParserTests
```

Expected: The six new tests fail (`extractSummary` is undefined; `parse` still contains `<summary>` in displayText).

- [ ] **Step 3: Implement extractor + tag-strip step**

Modify `Sources/Nous/Services/ClarificationCardParser.swift`:

Add these patterns near the existing private constants (after `internalReasoningPatterns`):

```swift
private static let summaryPattern = #"<summary>([\s\S]*?)</summary>"#

/// Open/close tags of <summary>. Used to strip the tag markers out of chat display
/// text while preserving the inner markdown, so the summary reads naturally in the
/// chat bubble and the panel renders the same content in document style.
private static let summaryTagMarkerPattern = #"</?summary>"#
```

Add the public extractor (place it right after `parse`):

```swift
static func extractSummary(from text: String) -> String? {
    guard
        let regex = try? NSRegularExpression(
            pattern: summaryPattern,
            options: [.caseInsensitive]
        ),
        let range = nsRange(for: text),
        let match = regex.firstMatch(in: text, options: [], range: range),
        let innerRange = Range(match.range(at: 1), in: text)
    else {
        return nil
    }

    let inner = text[innerRange].trimmingCharacters(in: .whitespacesAndNewlines)
    return inner.isEmpty ? nil : inner
}
```

Add a content-preserving tag stripper:

```swift
private static func removingSummaryTagMarkers(from text: String) -> String {
    guard
        let regex = try? NSRegularExpression(
            pattern: summaryTagMarkerPattern,
            options: [.caseInsensitive]
        ),
        let range = nsRange(for: text)
    else {
        return text
    }
    return regex.stringByReplacingMatches(
        in: text,
        options: [],
        range: range,
        withTemplate: ""
    )
}
```

Modify `parse(_:)` to run the new stripper on `sanitizedText`. Change line 17 from:

```swift
let sanitizedText = removingInternalReasoningMarkers(from: text)
```

to:

```swift
let sanitizedText = removingSummaryTagMarkers(
    from: removingInternalReasoningMarkers(from: text)
)
```

- [ ] **Step 4: Run tests, verify pass**

```bash
./scripts/test_nous.sh -only-testing:NousTests/ClarificationCardParserTests
```

Expected: All tests (existing + 6 new) pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Services/ClarificationCardParser.swift \
        Tests/NousTests/ClarificationCardParserTests.swift
git commit -m "feat(parser): extract <summary> content + strip tags in chat display"
```

---

## Task 2: `ScratchSummary` model + `ScratchPadStore`

**Files:**
- Create: `Sources/Nous/Models/ScratchSummary.swift`
- Create: `Sources/Nous/Services/ScratchPadStore.swift`
- Test: `Tests/NousTests/ScratchPadStoreTests.swift`
- Modify: `project.yml` (no textual change, but run `xcodegen` at the end of this task)

- [ ] **Step 1: Create the value type**

Write `Sources/Nous/Models/ScratchSummary.swift`:

```swift
import Foundation

/// A snapshot of an LLM-generated summary captured from a Nous assistant reply.
/// The `markdown` is the inner content of a <summary>…</summary> block; the tag
/// markers themselves are stripped before storage.
struct ScratchSummary: Codable, Equatable {
    let markdown: String
    let generatedAt: Date
    let sourceMessageId: UUID
}
```

- [ ] **Step 2: Write failing tests**

Create `Tests/NousTests/ScratchPadStoreTests.swift`:

```swift
import XCTest
@testable import Nous

final class ScratchPadStoreTests: XCTestCase {

    private var defaultsSuite: UserDefaults!

    override func setUp() {
        super.setUp()
        let suiteName = "ScratchPadStoreTests.\(UUID().uuidString)"
        defaultsSuite = UserDefaults(suiteName: suiteName)!
        defaultsSuite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaultsSuite = nil
        super.tearDown()
    }

    private func makeStore() -> ScratchPadStore {
        ScratchPadStore(defaults: defaultsSuite)
    }

    private func summary(_ markdown: String, at date: Date = Date()) -> ScratchSummary {
        ScratchSummary(markdown: markdown, generatedAt: date, sourceMessageId: UUID())
    }

    // MARK: - Ingest

    func testIngestStoresLatestSummaryWhenContentPresent() {
        let store = makeStore()
        let s = summary("# Title\n\nBody")
        store.ingest(summary: s)
        XCTAssertEqual(store.latestSummary, s)
    }

    func testIngestLaterSummaryReplacesLatest() {
        let store = makeStore()
        let first = summary("# First", at: Date(timeIntervalSince1970: 1000))
        let second = summary("# Second", at: Date(timeIntervalSince1970: 2000))
        store.ingest(summary: first)
        store.ingest(summary: second)
        XCTAssertEqual(store.latestSummary, second)
    }

    // MARK: - Load logic

    func testOnPanelOpenedWithEmptyContentLoadsSummarySilently() {
        let store = makeStore()
        let s = summary("# Hello")
        store.ingest(summary: s)

        store.onPanelOpened()

        XCTAssertEqual(store.currentContent, "# Hello")
        XCTAssertEqual(store.baseSnapshot, "# Hello")
        XCTAssertEqual(store.contentBaseGeneratedAt, s.generatedAt)
        XCTAssertNil(store.pendingOverwrite)
        XCTAssertFalse(store.isDirty)
    }

    func testOnPanelOpenedWithFreeTypedContentAndFirstSummaryQueuesOverwrite() {
        let store = makeStore()
        store.updateContent("my own notes")   // no summary yet; free-typing
        XCTAssertFalse(store.isDirty)        // zero-base while no summary

        let s = summary("# Auto")
        store.ingest(summary: s)
        store.onPanelOpened()

        XCTAssertEqual(store.currentContent, "my own notes")
        XCTAssertEqual(store.pendingOverwrite, s)
    }

    func testOnPanelOpenedSameBaseReloadIsNoOp() {
        let store = makeStore()
        let s = summary("# A")
        store.ingest(summary: s)
        store.onPanelOpened()

        store.updateContent("# A — with my edits")
        XCTAssertTrue(store.isDirty)

        store.onPanelOpened()   // same latest, already based on it
        XCTAssertEqual(store.currentContent, "# A — with my edits")
        XCTAssertNil(store.pendingOverwrite)
    }

    func testOnPanelOpenedNewerSummaryWithCleanContentOverwritesSilently() {
        let store = makeStore()
        let first = summary("# First", at: Date(timeIntervalSince1970: 1))
        store.ingest(summary: first)
        store.onPanelOpened()

        let second = summary("# Second", at: Date(timeIntervalSince1970: 2))
        store.ingest(summary: second)
        store.onPanelOpened()

        XCTAssertEqual(store.currentContent, "# Second")
        XCTAssertEqual(store.baseSnapshot, "# Second")
        XCTAssertEqual(store.contentBaseGeneratedAt, second.generatedAt)
        XCTAssertNil(store.pendingOverwrite)
    }

    func testOnPanelOpenedNewerSummaryWithDirtyContentQueuesOverwrite() {
        let store = makeStore()
        let first = summary("# First", at: Date(timeIntervalSince1970: 1))
        store.ingest(summary: first)
        store.onPanelOpened()

        store.updateContent("# First — edited")
        XCTAssertTrue(store.isDirty)

        let second = summary("# Second", at: Date(timeIntervalSince1970: 2))
        store.ingest(summary: second)
        store.onPanelOpened()

        XCTAssertEqual(store.currentContent, "# First — edited")  // untouched
        XCTAssertEqual(store.pendingOverwrite, second)
    }

    // MARK: - Accept / Reject

    func testAcceptPendingOverwriteApplies() {
        let store = makeStore()
        store.ingest(summary: summary("# A"))
        store.onPanelOpened()
        store.updateContent("# A — edits")
        let next = summary("# B", at: Date(timeIntervalSince1970: 99))
        store.ingest(summary: next)
        store.onPanelOpened()

        store.acceptPendingOverwrite()

        XCTAssertEqual(store.currentContent, "# B")
        XCTAssertEqual(store.baseSnapshot, "# B")
        XCTAssertEqual(store.contentBaseGeneratedAt, next.generatedAt)
        XCTAssertNil(store.pendingOverwrite)
        XCTAssertFalse(store.isDirty)
    }

    func testRejectPendingOverwriteLeavesStateUntouched() {
        let store = makeStore()
        store.ingest(summary: summary("# A"))
        store.onPanelOpened()
        store.updateContent("# A — edits")
        let next = summary("# B", at: Date(timeIntervalSince1970: 99))
        store.ingest(summary: next)
        store.onPanelOpened()

        store.rejectPendingOverwrite()

        XCTAssertEqual(store.currentContent, "# A — edits")
        XCTAssertEqual(store.baseSnapshot, "# A")
        XCTAssertNil(store.pendingOverwrite)
    }

    // MARK: - Download

    func testMarkDownloadedResetsDirtyAgainstCurrentContent() {
        let store = makeStore()
        store.ingest(summary: summary("# A"))
        store.onPanelOpened()
        store.updateContent("# A — edits")
        XCTAssertTrue(store.isDirty)

        store.markDownloaded()

        XCTAssertEqual(store.baseSnapshot, "# A — edits")
        XCTAssertFalse(store.isDirty)
    }
}
```

- [ ] **Step 3: Run tests, verify failure**

```bash
./scripts/test_nous.sh -only-testing:NousTests/ScratchPadStoreTests
```

Expected: Compilation fails — `ScratchPadStore` does not exist.

- [ ] **Step 4: Implement the store**

Create `Sources/Nous/Services/ScratchPadStore.swift`:

```swift
import Foundation
import Observation

/// Owns the ScratchPad panel's state. Two independent fields track:
///   1. `latestSummary` — the most recent <summary> Nous has emitted.
///   2. `currentContent` / `baseSnapshot` / `contentBaseGeneratedAt` — what the
///      panel actually renders, the snapshot it was loaded from, and which
///      summary version produced that snapshot.
///
/// `isDirty` is derived (`currentContent != baseSnapshot`) and drives the "•" in
/// the panel header. `pendingOverwrite` is set only when a newer summary has
/// arrived but the user has unsaved edits; UI must show a confirm alert and then
/// call `acceptPendingOverwrite()` or `rejectPendingOverwrite()`.
@Observable
@MainActor
final class ScratchPadStore {

    // MARK: - Public state (observable)

    private(set) var latestSummary: ScratchSummary?
    private(set) var currentContent: String
    private(set) var baseSnapshot: String
    private(set) var contentBaseGeneratedAt: Date?
    private(set) var pendingOverwrite: ScratchSummary?

    var isDirty: Bool { currentContent != baseSnapshot }

    // MARK: - Dependencies

    private let defaults: UserDefaults

    private enum Keys {
        static let latestSummary = "nous.scratchpad.latestSummary"
        static let currentContent = "nous.scratchpad.content"
        static let baseSnapshot = "nous.scratchpad.baseSnapshot"
        static let baseDate = "nous.scratchpad.contentBaseDate"
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Keys.latestSummary),
           let decoded = try? JSONDecoder().decode(ScratchSummary.self, from: data) {
            self.latestSummary = decoded
        } else {
            self.latestSummary = nil
        }

        self.currentContent = defaults.string(forKey: Keys.currentContent) ?? ""
        self.baseSnapshot   = defaults.string(forKey: Keys.baseSnapshot) ?? ""

        if let raw = defaults.object(forKey: Keys.baseDate) as? Double {
            self.contentBaseGeneratedAt = Date(timeIntervalSince1970: raw)
        } else {
            self.contentBaseGeneratedAt = nil
        }

        self.pendingOverwrite = nil
    }

    // MARK: - Ingest (ChatViewModel → store)

    /// Called after an assistant reply is finalized. If the text contains a
    /// well-formed <summary> tag, captures it as the latest summary.
    /// No-ops otherwise.
    func ingestAssistantMessage(content: String, sourceMessageId: UUID, now: Date = Date()) {
        guard let markdown = ClarificationCardParser.extractSummary(from: content) else {
            return
        }
        let summary = ScratchSummary(
            markdown: markdown,
            generatedAt: now,
            sourceMessageId: sourceMessageId
        )
        ingest(summary: summary)
    }

    /// Lower-level ingestion used by tests and by `ingestAssistantMessage`.
    func ingest(summary: ScratchSummary) {
        latestSummary = summary
        persistLatestSummary()
    }

    // MARK: - Panel lifecycle

    /// Called when the panel becomes visible OR when `latestSummary` changes
    /// while the panel is already visible. Implements the load logic from §6
    /// of the spec.
    func onPanelOpened() {
        guard let latest = latestSummary else {
            // Empty state — free-typing mode, no action.
            return
        }

        if let base = contentBaseGeneratedAt, base == latest.generatedAt {
            // Already based on this summary; keep user edits as-is.
            return
        }

        if !isDirty {
            applyOverwrite(to: latest)
            return
        }

        // Dirty + newer summary → queue for user confirmation.
        pendingOverwrite = latest
    }

    func acceptPendingOverwrite() {
        guard let next = pendingOverwrite else { return }
        applyOverwrite(to: next)
        pendingOverwrite = nil
    }

    func rejectPendingOverwrite() {
        pendingOverwrite = nil
    }

    // MARK: - Edits

    func updateContent(_ newValue: String) {
        currentContent = newValue
        defaults.set(newValue, forKey: Keys.currentContent)

        // Free-typing in empty state: keep base glued to content so isDirty stays
        // false until the first summary lands.
        if latestSummary == nil && contentBaseGeneratedAt == nil {
            baseSnapshot = newValue
            defaults.set(newValue, forKey: Keys.baseSnapshot)
        }
    }

    /// Called by the panel after NSSavePanel completes successfully. The on-disk
    /// file becomes the new clean baseline; `contentBaseGeneratedAt` is left
    /// untouched so a newer summary still counts as "newer than what's shown".
    func markDownloaded() {
        baseSnapshot = currentContent
        defaults.set(currentContent, forKey: Keys.baseSnapshot)
    }

    // MARK: - Helpers

    private func applyOverwrite(to summary: ScratchSummary) {
        currentContent = summary.markdown
        baseSnapshot = summary.markdown
        contentBaseGeneratedAt = summary.generatedAt
        defaults.set(summary.markdown, forKey: Keys.currentContent)
        defaults.set(summary.markdown, forKey: Keys.baseSnapshot)
        defaults.set(summary.generatedAt.timeIntervalSince1970, forKey: Keys.baseDate)
    }

    private func persistLatestSummary() {
        guard let latest = latestSummary,
              let data = try? JSONEncoder().encode(latest) else {
            defaults.removeObject(forKey: Keys.latestSummary)
            return
        }
        defaults.set(data, forKey: Keys.latestSummary)
    }
}
```

- [ ] **Step 5: Add new files to the Xcode project**

Run xcodegen so the new source + test files are picked up by the `.xcodeproj`:

```bash
xcodegen generate --spec project.yml
```

If xcodegen is not installed: `brew install xcodegen`.

- [ ] **Step 6: Run tests, verify pass**

```bash
./scripts/test_nous.sh -only-testing:NousTests/ScratchPadStoreTests
```

Expected: All nine tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/Models/ScratchSummary.swift \
        Sources/Nous/Services/ScratchPadStore.swift \
        Tests/NousTests/ScratchPadStoreTests.swift \
        Nous.xcodeproj
git commit -m "feat(scratchpad): ScratchPadStore with dirty/base-snapshot semantics"
```

---

## Task 3: Wire `ScratchPadStore` into `ChatViewModel` (ingest on message completion)

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Test: `Tests/NousTests/ChatViewModelTests.swift`

- [ ] **Step 1: Write the failing integration test**

Open `Tests/NousTests/ChatViewModelTests.swift`. Find where a `ChatViewModel` test harness is set up (search for `makeViewModel` or similar factory). Add this test inside the existing `ChatViewModelTests` class; if the harness takes a `scratchPadStore:` param it doesn't have yet, we'll add it in the next step.

```swift
func testIngestsSummaryFromAssistantReply() {
    let store = ScratchPadStore(defaults: makeIsolatedDefaults())
    let vm = makeViewModel(scratchPadStore: store)

    let raw = """
    搞掂。
    <summary>
    # 今次倾咗乜

    ## 问题
    Alex 想搞清楚 Notion 点走。

    ## 思考
    倾咗 AI agent 嘅取舍。

    ## 结论
    唔加。

    ## 下一步
    - 观察三个月
    </summary>
    """
    let msg = Message(nodeId: UUID(), role: .assistant, content: raw)
    store.ingestAssistantMessage(content: msg.content, sourceMessageId: msg.id)

    XCTAssertNotNil(store.latestSummary)
    XCTAssertTrue(store.latestSummary!.markdown.hasPrefix("# 今次倾咗乜"))
    XCTAssertEqual(store.latestSummary!.sourceMessageId, msg.id)
}

/// Helper for tests that need a disposable UserDefaults suite.
private func makeIsolatedDefaults() -> UserDefaults {
    let name = "ChatViewModelTests.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}
```

If the existing `makeViewModel` factory is complex and hard to extend, instead write this as a standalone test class `ChatViewModelSummaryIngestTests` that uses `ScratchPadStore` directly (as above — the assertion only touches the store, not the ChatViewModel). Name it to fit whichever file organization already exists.

- [ ] **Step 2: Run test, verify failure**

```bash
./scripts/test_nous.sh -only-testing:NousTests/ChatViewModelTests/testIngestsSummaryFromAssistantReply
```

Expected: compile error about missing `scratchPadStore:` parameter on `ChatViewModel.init` (if you wired it via the VM) OR test passes trivially if you wrote the standalone variant. In the standalone variant, still run it and confirm green, then proceed — the integration wiring below is the real production change.

- [ ] **Step 3: Add the dependency to `ChatViewModel`**

In `Sources/Nous/ViewModels/ChatViewModel.swift`:

At the dependencies block (around line 25-49), add:

```swift
    private let scratchPadStore: ScratchPadStore
```

In the `init(...)` parameter list, add the parameter at the end (keep defaults safe for tests):

```swift
    scratchPadStore: ScratchPadStore,
```

In the init body, assign:

```swift
    self.scratchPadStore = scratchPadStore
```

- [ ] **Step 4: Call ingest at both finish sites**

**Site A (around line 301-309, companion flow):**

After:
```swift
        let assistantContent = currentResponse
        let assistantMessage = Message(nodeId: node.id, role: .assistant, content: assistantContent)
        try? nodeStore.insertMessage(assistantMessage)
        messages.append(assistantMessage)
        persistConversationSnapshot(for: node.id, messages: messages, shouldRefreshEmoji: true)
        activeQuickActionMode = ChatViewModel.updatedQuickActionMode(
            currentMode: activeQuickActionMode,
            assistantContent: assistantContent
        )
```

Add immediately below:
```swift
        scratchPadStore.ingestAssistantMessage(
            content: assistantContent,
            sourceMessageId: assistantMessage.id
        )
```

**Site B (around line 682-700, RAG pipeline flow):**

After:
```swift
        let assistantMessage = Message(
            nodeId: node.id,
            role: .assistant,
            content: assistantContent,
            thinkingContent: persistedThinking
        )
        try? nodeStore.insertMessage(assistantMessage)
        messages.append(assistantMessage)
```

Add immediately below (before the `try? nodeStore.updateJudgeEventMessageId` line):
```swift
        scratchPadStore.ingestAssistantMessage(
            content: assistantContent,
            sourceMessageId: assistantMessage.id
        )
```

- [ ] **Step 5: Update every `ChatViewModel(...)` construction site**

Search and update:

```bash
grep -rn "ChatViewModel(" Sources Tests
```

For each call site (`AppEnvironment.makeDependencies`, any test factories, previews), thread a `ScratchPadStore` through. In tests that don't care, pass `ScratchPadStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)`.

Wiring in `AppEnvironment` happens in Task 4 — for now, adjust only test factories so the project compiles.

- [ ] **Step 6: Run tests, verify pass**

```bash
./scripts/test_nous.sh -only-testing:NousTests/ChatViewModelTests
```

Expected: All tests pass, including the new `testIngestsSummaryFromAssistantReply`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift \
        Tests/NousTests/ChatViewModelTests.swift
git commit -m "feat(chat): publish <summary> content to ScratchPadStore on reply finish"
```

---

## Task 4: Thread `ScratchPadStore` through `AppDependencies`

**Files:**
- Modify: `Sources/Nous/App/AppEnvironment.swift`
- Modify: `Sources/Nous/App/ContentView.swift`

- [ ] **Step 1: Add to `AppDependencies`**

In `Sources/Nous/App/AppEnvironment.swift`:

Inside `struct AppDependencies` (the list starting at line 10), add:

```swift
    let scratchPadStore: ScratchPadStore
```

- [ ] **Step 2: Build it in `makeDependencies`**

Inside `makeDependencies()`, before the `ChatViewModel(...)` construction, add:

```swift
        let scratchPadStore = ScratchPadStore()
```

Thread it into the `ChatViewModel(...)` init (use the new parameter added in Task 3).

In the final `return AppDependencies(...)` literal, add:

```swift
            scratchPadStore: scratchPadStore,
```

in the field list (ordering matches `AppDependencies` field order).

- [ ] **Step 3: Pass the store into `ScratchPadPanel`**

In `Sources/Nous/App/ContentView.swift`, line 114-117:

Replace:
```swift
            if isScratchPadVisible && selectedTab == .chat {
                ScratchPadPanel(isVisible: $isScratchPadVisible)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
```

with:
```swift
            if isScratchPadVisible && selectedTab == .chat,
               case .ready(let dependencies) = env.state {
                ScratchPadPanel(
                    isVisible: $isScratchPadVisible,
                    store: dependencies.scratchPadStore
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
```

(Task 6 will change `ScratchPadPanel` to accept this `store:` parameter — for now the compile break is expected and caught in Step 4.)

- [ ] **Step 4: Verify build still compiles apart from the expected `ScratchPadPanel` parameter mismatch**

```bash
xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' 2>&1 | tail -40
```

Expected: Error only at `ScratchPadPanel(isVisible:store:)` call site. No other errors.

- [ ] **Step 5: Commit (WIP is acceptable — panel refactor lands next)**

```bash
git add Sources/Nous/App/AppEnvironment.swift Sources/Nous/App/ContentView.swift
git commit -m "feat(app): expose ScratchPadStore via AppDependencies"
```

---

## Task 5: Add `summaryOutputPolicy` stable prompt layer

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift`
- Test: `Tests/NousTests/ChatViewModelTests.swift`

- [ ] **Step 1: Write the failing governance-trace test**

In `Tests/NousTests/ChatViewModelTests.swift`, add:

```swift
func testGovernanceTraceIncludesSummaryOutputPolicyLayer() {
    let trace = ChatViewModel.governanceTrace(
        chatMode: .companion,
        currentUserInput: "hello",
        globalMemory: nil,
        essentialStory: nil,
        projectMemory: nil,
        conversationMemory: nil,
        memoryEvidence: [],
        recentConversations: [],
        userModel: nil,
        projectGoal: nil,
        attachments: [],
        activeQuickActionMode: nil,
        allowInteractiveClarification: false
    )
    XCTAssertTrue(
        trace.promptLayers.contains("summary_output_policy"),
        "Expected stable layer 'summary_output_policy' in \(trace.promptLayers)"
    )
}

func testAssembleContextStableIncludesSummaryInstruction() {
    let slice = ChatViewModel.assembleContext(
        chatMode: .companion,
        currentUserInput: "hello",
        globalMemory: nil,
        essentialStory: nil,
        projectMemory: nil,
        conversationMemory: nil,
        memoryEvidence: [],
        recentConversations: [],
        userModel: nil,
        citations: [],
        projectGoal: nil,
        attachments: [],
        activeQuickActionMode: nil,
        allowInteractiveClarification: false
    )
    XCTAssertTrue(slice.stable.contains("<summary>"), "Stable system prompt must mention <summary> tag.")
    XCTAssertTrue(slice.stable.contains("## 下一步"))
}
```

(If `ChatViewModel.governanceTrace` / `ChatViewModel.assembleContext` have different positional/optional arguments in this codebase, adjust the test call to match — the assertions are the intent.)

- [ ] **Step 2: Run test, verify failure**

```bash
./scripts/test_nous.sh -only-testing:NousTests/ChatViewModelTests/testGovernanceTraceIncludesSummaryOutputPolicyLayer
```

Expected: Fail (`summary_output_policy` is not in the layers list).

- [ ] **Step 3: Add the stable policy constant**

In `Sources/Nous/ViewModels/ChatViewModel.swift`, near the other stable constants (search for `private static let coreSafetyPolicy`), add immediately after it:

```swift
    private static let summaryOutputPolicy = """
    ---

    SUMMARY OUTPUT POLICY:
    When Alex asks you to summarize the current conversation (keywords and intents include "总结", "summarize", "repo", "做笔记", "summary", "整份笔记", or equivalents), wrap the summary body in <summary>…</summary>. Inside the tag, use this exact markdown structure:

      # <concise title — used as the download filename>

      ## 问题
      <one narrative paragraph: what triggered the discussion>

      ## 思考
      <one narrative paragraph: the path the conversation took, including pivots>

      ## 结论
      <one narrative paragraph: consensus or decisions reached>

      ## 下一步
      - <short actionable bullet>
      - <another>

    Paragraphs must be narrative prose, not bullet dumps. The # title must contain no filename-unsafe characters (avoid /\\:*?"<>|).

    Text outside the tag is allowed for a brief conversational wrapper (e.g. "整好了，睇下右边嘅白纸"). The summary content itself must strictly live inside the tag. Never emit the tag when Alex is not asking for a summary.
    """
```

- [ ] **Step 4: Append it to the stable list in `assembleContext`**

Around line 867-869, change:

```swift
        stable.append(anchor)
        stable.append(memoryInterpretationPolicy)
        stable.append(coreSafetyPolicy)
```

to:

```swift
        stable.append(anchor)
        stable.append(memoryInterpretationPolicy)
        stable.append(coreSafetyPolicy)
        stable.append(summaryOutputPolicy)
```

- [ ] **Step 5: Update `governanceTrace` layer list**

Around line 1013, change:

```swift
        var layers = ["anchor", "memory_interpretation_policy", "core_safety_policy", "chat_mode"]
```

to:

```swift
        var layers = ["anchor", "memory_interpretation_policy", "core_safety_policy", "summary_output_policy", "chat_mode"]
```

- [ ] **Step 6: Run tests, verify pass**

```bash
./scripts/test_nous.sh -only-testing:NousTests/ChatViewModelTests
```

Expected: All ChatViewModel tests pass, including the two new ones.

- [ ] **Step 7: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift \
        Tests/NousTests/ChatViewModelTests.swift
git commit -m "feat(prompt): summary_output_policy stable layer — wrap summaries in <summary>"
```

---

## Task 6: `ScratchPadPanel` — white-paper visual overhaul + load wiring

**Files:**
- Modify: `Sources/Nous/Views/ScratchPadPanel.swift`
- Modify: `Sources/Nous/Views/ChatArea.swift` (add toggle entry point — see prerequisite)

This task replaces the body of `ScratchPadPanel` with a document-style layout and accepts the store. It does NOT yet implement download; that lands in Task 8. Overwrite alert lands in Task 7.

**Prerequisite carried over from Task 4:** Right now `ContentView.isScratchPadVisible` has no UI to toggle it to `true`. The toggle button (a `note.text` glass chip in the top-right) used to live in a stashed thinking-accordion WIP and isn't in the current tree. Before (or as the first step of) this task, add a `@Binding var isScratchPadVisible: Bool` to `ChatArea` and a ~10-line button that calls `isScratchPadVisible.toggle()`. Update `ContentView.swift` to pass `isScratchPadVisible: $isScratchPadVisible` to `ChatArea`. Without this, the panel is unreachable and Task 9's smoke checks can't run.

- [ ] **Step 1: Change the struct signature and remove the old `@AppStorage` field**

In `Sources/Nous/Views/ScratchPadPanel.swift`:

Replace the struct up to (but not including) `var body: some View {` with:

```swift
struct ScratchPadPanel: View {
    @Binding var isVisible: Bool
    @Bindable var store: ScratchPadStore
    @State private var isPreviewMode = false
```

(Remove the `@AppStorage("nous.scratchpad.content") private var content = ""` line — `store.currentContent` is the source of truth now.)

- [ ] **Step 2: Rewrite `var body` with the white-paper surface**

Replace the existing `var body: some View { ... }` with:

```swift
    var body: some View {
        NativeGlassPanel(cornerRadius: 32, tintColor: AppColor.glassTint) {
            VStack(alignment: .leading, spacing: 0) {
                header
                divider
                paperSurface
            }
            .padding(.bottom, 12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(AppColor.panelStroke, lineWidth: 1)
        )
        .frame(width: 420)
        .onAppear { store.onPanelOpened() }
        .onChange(of: store.latestSummary) { _, _ in
            if isVisible { store.onPanelOpened() }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColor.colaOrange)

            Text("白纸")
                .font(.system(size: 15, weight: .bold, design: .serif))
                .foregroundColor(AppColor.colaDarkText)

            if store.isDirty {
                Text("• 未保存")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppColor.secondaryText)
            }

            Spacer(minLength: 0)

            downloadButton

            HStack(spacing: 2) {
                modeButton(label: "Write", icon: "pencil", active: !isPreviewMode) {
                    withAnimation(.easeInOut(duration: 0.15)) { isPreviewMode = false }
                }
                modeButton(label: "Preview", icon: "eye", active: isPreviewMode) {
                    withAnimation(.easeInOut(duration: 0.15)) { isPreviewMode = true }
                }
            }
            .padding(3)
            .background(AppColor.subtleFill)
            .clipShape(Capsule())

            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isVisible = false
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(AppColor.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(AppColor.subtleFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // Placeholder — real impl lands in Task 8.
    @ViewBuilder
    private var downloadButton: some View { EmptyView() }

    @ViewBuilder
    private var divider: some View {
        Rectangle()
            .fill(AppColor.panelStroke)
            .frame(height: 0.5)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
    }

    // MARK: - Paper surface

    @ViewBuilder
    private var paperSurface: some View {
        paperContainer {
            if store.latestSummary == nil && store.currentContent.isEmpty {
                emptyState
            } else if isPreviewMode {
                MarkdownPreview(markdown: store.currentContent)
            } else {
                TextEditor(text: editorBinding)
                    .font(.system(size: 14, design: .serif))
                    .foregroundColor(AppColor.colaDarkText)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .lineSpacing(6)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func paperContainer<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        inner()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 254/255, green: 252/255, blue: 248/255))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.04), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("想开始？")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundColor(AppColor.colaDarkText)
            Text("喺左边同 Nous 倾一阵，叫佢「总结一下」。生成嘅 summary 会自动出喺呢度，之后你仲可以手动改同下载。")
                .font(.system(size: 13, design: .serif))
                .foregroundColor(AppColor.secondaryText)
                .lineSpacing(6)

            TextEditor(text: editorBinding)
                .font(.system(size: 13, design: .serif))
                .foregroundColor(AppColor.colaDarkText)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: 120)
                .padding(.top, 8)
        }
    }

    private var editorBinding: Binding<String> {
        Binding(
            get: { store.currentContent },
            set: { store.updateContent($0) }
        )
    }
```

(Keep the existing `modeButton(...)` helper and the `MarkdownPreview` / `MarkdownBlock` types below the struct unchanged.)

- [ ] **Step 3: Build**

```bash
xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' 2>&1 | tail -40
```

Expected: build succeeds. No warnings about unused `@AppStorage`.

- [ ] **Step 4: Run the whole test suite**

```bash
./scripts/test_nous.sh
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/ScratchPadPanel.swift
git commit -m "feat(scratchpad): white-paper surface, 420pt width, serif body, store-backed"
```

---

## Task 7: Overwrite-protection alert

**Files:**
- Modify: `Sources/Nous/Views/ScratchPadPanel.swift`

- [ ] **Step 1: Add the alert modifier**

In `ScratchPadPanel`, modify the top-level `var body` to attach an alert bound to `store.pendingOverwrite`:

Replace:

```swift
        .frame(width: 420)
        .onAppear { store.onPanelOpened() }
        .onChange(of: store.latestSummary) { _, _ in
            if isVisible { store.onPanelOpened() }
        }
```

with:

```swift
        .frame(width: 420)
        .onAppear { store.onPanelOpened() }
        .onChange(of: store.latestSummary) { _, _ in
            if isVisible { store.onPanelOpened() }
        }
        .alert(
            "有新嘅 summary",
            isPresented: Binding(
                get: { store.pendingOverwrite != nil },
                set: { newValue in
                    if newValue == false && store.pendingOverwrite != nil {
                        store.rejectPendingOverwrite()
                    }
                }
            ),
            presenting: store.pendingOverwrite
        ) { _ in
            Button("替换", role: .destructive) { store.acceptPendingOverwrite() }
            Button("保留现有", role: .cancel) { store.rejectPendingOverwrite() }
        } message: { _ in
            Text("你喺白纸度仲有未下载嘅改动。要用新嘅 summary 替换吗？")
        }
```

- [ ] **Step 2: Build**

```bash
xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: no errors.

- [ ] **Step 3: Smoke test manually**

Launch the app. Create a chat, ask Nous to summarize (e.g. type "总结一下"). Open the scratchpad, edit the loaded text, ask Nous to summarize again. Confirm the alert appears with 替换 / 保留现有 buttons and each button behaves as described.

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Views/ScratchPadPanel.swift
git commit -m "feat(scratchpad): confirm alert when newer summary arrives with dirty edits"
```

---

## Task 8: Download — filename slug + `NSSavePanel`

**Files:**
- Create: `Sources/Nous/Views/FilenameSlug.swift`
- Test: `Tests/NousTests/FilenameSlugTests.swift`
- Modify: `Sources/Nous/Views/ScratchPadPanel.swift`

- [ ] **Step 1: Write failing slug tests**

Create `Tests/NousTests/FilenameSlugTests.swift`:

```swift
import XCTest
@testable import Nous

final class FilenameSlugTests: XCTestCase {

    private let fallbackDate = Date(timeIntervalSince1970: 1_713_657_600)   // 2024-04-20 UTC

    func testUsesFirstH1AsSlug() {
        let md = "# Hello World\n\nBody"
        XCTAssertEqual(filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate), "Hello-World.md")
    }

    func testPreservesCJK() {
        let md = "# 关于 Notion 产品方向\n\n..."
        let result = filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate)
        XCTAssertTrue(result.contains("关于"))
        XCTAssertTrue(result.contains("Notion"))
        XCTAssertTrue(result.hasSuffix(".md"))
    }

    func testStripsDisallowedPathChars() {
        let md = "# bad/name:with*chars?\n"
        let result = filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate)
        XCTAssertFalse(result.contains("/"))
        XCTAssertFalse(result.contains(":"))
        XCTAssertFalse(result.contains("*"))
        XCTAssertFalse(result.contains("?"))
    }

    func testFallsBackToDateWhenNoH1() {
        let md = "no heading here\n\nblah"
        XCTAssertEqual(filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate), "Nous-Summary-2024-04-20.md")
    }

    func testFallsBackWhenH1Empty() {
        let md = "#   \n\nbody"
        XCTAssertEqual(filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate), "Nous-Summary-2024-04-20.md")
    }

    func testTruncatesAtSixtyChars() {
        let longTitle = String(repeating: "a", count: 200)
        let md = "# \(longTitle)\n"
        let result = filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate)
        let stem = result.replacingOccurrences(of: ".md", with: "")
        XCTAssertLessThanOrEqual(stem.count, 60)
    }

    func testCollapsesWhitespaceToDashes() {
        let md = "# the    quick    brown\n"
        XCTAssertEqual(filenameSlug(fromMarkdown: md, fallbackDate: fallbackDate), "the-quick-brown.md")
    }
}
```

- [ ] **Step 2: Run tests, verify failure**

```bash
./scripts/test_nous.sh -only-testing:NousTests/FilenameSlugTests
```

Expected: compile error — `filenameSlug` undefined.

- [ ] **Step 3: Implement slug**

Create `Sources/Nous/Views/FilenameSlug.swift`:

```swift
import Foundation

/// Returns a `.md` filename derived from the first ATX H1 (`# ...`) in the given
/// markdown. Falls back to `Nous-Summary-YYYY-MM-DD.md` when no usable heading
/// exists. Strips filename-unsafe characters (`/\:*?"<>|` and control chars),
/// collapses whitespace to single dashes, and truncates the stem to 60 chars.
func filenameSlug(fromMarkdown markdown: String, fallbackDate: Date = Date()) -> String {
    let heading = extractFirstH1(from: markdown)
    if let slug = slugify(heading) {
        return "\(slug).md"
    }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return "Nous-Summary-\(formatter.string(from: fallbackDate)).md"
}

private func extractFirstH1(from markdown: String) -> String {
    for line in markdown.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("# "), !trimmed.hasPrefix("## ") else { continue }
        return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    return ""
}

private func slugify(_ raw: String) -> String? {
    guard !raw.isEmpty else { return nil }

    let disallowed: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
    var filtered = String(raw.unicodeScalars.compactMap { scalar -> Character? in
        if scalar.properties.generalCategory == .control { return nil }
        let ch = Character(scalar)
        if disallowed.contains(ch) { return nil }
        return ch
    })

    // Collapse whitespace runs to single dash.
    let whitespaceCollapsed = filtered
        .components(separatedBy: .whitespaces)
        .filter { !$0.isEmpty }
        .joined(separator: "-")
    filtered = whitespaceCollapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    guard !filtered.isEmpty else { return nil }

    // Truncate stem to 60 chars (character count, not bytes — CJK stays readable).
    if filtered.count > 60 {
        let idx = filtered.index(filtered.startIndex, offsetBy: 60)
        filtered = String(filtered[..<idx])
    }
    return filtered
}
```

- [ ] **Step 4: Add file to project, run tests**

```bash
xcodegen generate --spec project.yml
./scripts/test_nous.sh -only-testing:NousTests/FilenameSlugTests
```

Expected: all seven tests pass.

- [ ] **Step 5: Implement `downloadButton` + save flow in `ScratchPadPanel`**

In `Sources/Nous/Views/ScratchPadPanel.swift`, at the top add:

```swift
import AppKit
```

(if not already imported — SwiftUI alone does not expose `NSSavePanel`).

Replace the placeholder `downloadButton` body:

```swift
    @ViewBuilder
    private var downloadButton: some View { EmptyView() }
```

with:

```swift
    @ViewBuilder
    private var downloadButton: some View {
        Button(action: handleDownload) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text("下载")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppColor.colaOrange)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(store.currentContent.isEmpty)
    }

    private func handleDownload() {
        let content = store.currentContent
        guard !content.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "下载白纸"
        panel.nameFieldStringValue = filenameSlug(fromMarkdown: content)
        panel.canCreateDirectories = true
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType]
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try content.data(using: .utf8)?.write(to: url, options: .atomic)
                store.markDownloaded()
            } catch {
                let alert = NSAlert()
                alert.messageText = "保存失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }
```

Add the import at the top of the file if missing:

```swift
import UniformTypeIdentifiers
```

- [ ] **Step 6: Build**

```bash
xcodebuild build -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: no errors.

- [ ] **Step 7: Manual smoke**

Run the app. Ask Nous to summarize. Open the scratchpad. Tap 下载. Confirm:
1. `NSSavePanel` opens with a sensible default filename (the h1 slug).
2. Saving writes the file correctly (open it in Finder / a text editor).
3. After save, the "• 未保存" indicator disappears.

- [ ] **Step 8: Commit**

```bash
git add Sources/Nous/Views/FilenameSlug.swift \
        Sources/Nous/Views/ScratchPadPanel.swift \
        Tests/NousTests/FilenameSlugTests.swift \
        Nous.xcodeproj
git commit -m "feat(scratchpad): download white paper as .md via NSSavePanel"
```

---

## Task 9: End-to-end smoke checklist + final housekeeping

- [ ] **Step 1: Run the full test suite**

```bash
./scripts/test_nous.sh
```

Expected: all green.

- [ ] **Step 2: Manual smoke checklist (run each, fix any failure before marking done)**

1. **Basic summary flow** — Start a fresh chat. Have at least 3-4 user turns of real discussion. Type "总结一下". Observe:
   - Chat bubble shows the summary content cleanly, no raw `<summary>` or `</summary>` strings.
   - Tap the top-right `note.text` toggle: panel slides in from the right at 420pt wide.
   - White-paper surface renders with serif body, warm off-white background, subtle shadow.
   - The H1 and section headings (问题 / 思考 / 结论 / 下一步) are present.

2. **Edit + dirty indicator** — In the panel, edit the markdown. Header shows `• 未保存`. Close and reopen the panel — edits persist.

3. **Newer-summary + dirty protection** — With unsaved edits still in the panel, type another "总结一下" in chat. On the next reply, either the panel is already open or open it: the alert "有新嘅 summary" appears. Tap "保留现有" — content unchanged. Repeat, tap "替换" — content now matches the latest summary, dirty indicator gone.

4. **Clean reload** — Close the panel, ask for yet another summary, open the panel — content silently updates to the newest (no dialog) because base matched the previously accepted overwrite.

5. **Download** — Tap 下载. `NSSavePanel` default filename starts with the summary's H1 (slugified). Save. Open the file — content matches the panel exactly. Dirty indicator gone.

6. **Empty state** — New chat before any summary. Open panel. Paper shows "想开始？…" copy and a serif `TextEditor` for free-typing. Free-typing does not set dirty (nothing to compare against). First summary arrival after free-typing triggers the overwrite alert.

7. **Non-summary replies unaffected** — Ask Nous a normal question (not a summary). Reply does not contain `<summary>` tag; chat renders normally; `store.latestSummary` unchanged (verify via reopening the panel — previous summary still shown).

- [ ] **Step 3: Commit anything that got tweaked during smoke**

If any fixes were needed:

```bash
git status
git add <whatever>
git commit -m "fix(scratchpad): <specific issue from smoke>"
```

- [ ] **Step 4: Push branch (do NOT auto-push; ask user first)**

Do not push without explicit user confirmation. Ask: "Ready to push / open PR?"

---

## Self-Review Notes (for plan authors, not the executor)

**Spec coverage audit:**
- §4 Core Flow → Tasks 3 (ingest), 6 (onAppear load), 7 (alert), 8 (download). ✅
- §5 LLM Contract → Task 5 (prompt layer). Parser split: Task 1. ✅
- §6 Data Model / State → Tasks 2, 4. ✅
- §7 Visual → Task 6. ✅
- §8 Interactions (download, dirty) → Tasks 7, 8. ✅
- §9 Error / edge cases → covered via ScratchPadStore tests (Task 2) and FilenameSlug tests (Task 8). ✅
- §10 Testing → parser (Task 1), store (Task 2), chat VM integration (Task 3), governance layer (Task 5), slug (Task 8). Manual smoke (Task 9). ✅
- §11 File list → matches this plan's file map. ✅

**Type consistency check:**
- Store method names used consistently: `ingestAssistantMessage(content:sourceMessageId:)`, `ingest(summary:)`, `onPanelOpened()`, `updateContent(_:)`, `acceptPendingOverwrite()`, `rejectPendingOverwrite()`, `markDownloaded()`. ✅
- `ScratchSummary` fields — `markdown` / `generatedAt` / `sourceMessageId` — used identically in model, tests, store, and panel. ✅
- `filenameSlug(fromMarkdown:fallbackDate:)` — signature consistent across tests and call site. ✅

**Placeholder scan:** No TBD / TODO. Every code step has full code. ✅
