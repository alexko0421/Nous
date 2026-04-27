# Chat Markdown Structure (L2.5 Plan-fix) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Nous chat bubbles render markdown structure (headers / bullets / tables) and make Plan mode reliably produce a structured deliverable instead of degenerating into chat.

**Architecture:** New `ChatMarkdownRenderer` parses assistant text into typed `Segment` values (heading / bullet block / table / prose / verbatim) rendered in a SwiftUI `VStack`. `MessageBubble` splits user vs assistant rendering and routes assistant content through an `AssistantBubbleContent` helper view that binds a single `let segments = parse(displayText)` for both renderer and animation. Per-mode addendums get explicit format scaffolds; `PlanAgent.contextAddendum` switches on `turnIndex` with a defensive range pattern at the cap so the FINAL urgent contract reaches the model pre-execution. Markdown permission lives as a volatile chat-format policy in `ChatViewModel.assembleContext` (anchor.md is frozen by `AGENTS.md:39, 131`).

**Tech Stack:** Swift 5.x, SwiftUI (macOS 13+), XCTest, existing Nous codebase (no new dependencies).

**Spec source:** `docs/superpowers/specs/2026-04-26-chat-markdown-structure-design.md` (v5, post-codex round 5 PASS).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `Sources/Nous/Views/ChatMarkdownRenderer.swift` | Create | `Segment` enum, line-by-line `parse(text:) -> [Segment]`, sanitization, SwiftUI `View` rendering segments |
| `Sources/Nous/Views/ChatArea.swift` | Modify (≈line 532–611) | Refactor `MessageBubble`: split user vs assistant paths; add `AssistantBubbleContent` helper view |
| `Sources/Nous/Models/Agents/BrainstormAgent.swift` | Modify | Add bullet-hybrid constraint to `contextAddendum` turn 1+ |
| `Sources/Nous/Models/Agents/PlanAgent.swift` | Modify | Replace single addendum with switch on `turnIndex`: 0 → nil, 1 → decideOrAsk, cap... → final urgent (range), default → normal production with format scaffold |
| `Sources/Nous/ViewModels/ChatViewModel.swift` | Modify (≈line 920) | Insert `CHAT FORMAT POLICY` as first volatile piece in `assembleContext` |
| `Tests/NousTests/ChatMarkdownRendererTests.swift` | Create | Parser tests: heading / bullet / table / fence / sanitization / unclosed-fence-fallback |
| `Tests/NousTests/QuickActionAgentsTests.swift` | Modify | Extend with `BrainstormAgent` constraint test + `PlanAgent` 6-turn addendum tests (turns 0/1/2/3/4/5/6) |
| `Tests/NousTests/ClarificationCardParserTests.swift` | Modify | Add `<summary>` + markdown integration test |

---

## Task 1: ChatMarkdownRenderer skeleton — Segment enum + empty parser

**Files:**
- Create: `Sources/Nous/Views/ChatMarkdownRenderer.swift`
- Create: `Tests/NousTests/ChatMarkdownRendererTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/NousTests/ChatMarkdownRendererTests.swift`:

```swift
import XCTest
@testable import Nous

final class ChatMarkdownRendererTests: XCTestCase {

    // MARK: - Foundation

    func testEmptyInputReturnsEmptySegments() {
        XCTAssertEqual(ChatMarkdownRenderer.parse("").count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ChatMarkdownRendererTests`
Expected: FAIL — `ChatMarkdownRenderer` undefined.

- [ ] **Step 3: Create skeleton**

Create `Sources/Nous/Views/ChatMarkdownRenderer.swift`:

```swift
import SwiftUI

enum Segment: Equatable {
    case heading(level: Int, text: String)
    case bulletBlock([String])
    case table(headers: [String], rows: [[String]])
    case prose(String)
    case verbatim(String)
}

enum ChatMarkdownRenderer {

    /// Parses raw assistant text into typed segments. Line-based parsing.
    static func parse(_ text: String) -> [Segment] {
        return []
    }
}
```

Note: `ChatMarkdownRenderer` is declared as `enum` (no instances; pure namespace) for the parser. The SwiftUI view that consumes segments comes in Task 7 — it will be a separate `struct` named `ChatMarkdownView` to avoid name collision with the parser namespace.

- [ ] **Step 4: Re-add the file to the Xcode project**

The Nous project uses xcodegen. Run: `xcodegen generate`
Expected: `Generating project for Nous`. The new files are picked up automatically by xcodegen's directory glob.

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ChatMarkdownRendererTests`
Expected: PASS (1 test).

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/Views/ChatMarkdownRenderer.swift \
  Tests/NousTests/ChatMarkdownRendererTests.swift \
  Nous.xcodeproj/project.pbxproj
git commit -m "feat(chat-md): ChatMarkdownRenderer skeleton + Segment enum"
```

---

## Task 2: Heading parser

**Files:**
- Modify: `Sources/Nous/Views/ChatMarkdownRenderer.swift`
- Modify: `Tests/NousTests/ChatMarkdownRendererTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `ChatMarkdownRendererTests`:

```swift
// MARK: - Headings

func testH1Heading() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("# Title"),
        [.heading(level: 1, text: "Title")]
    )
}

func testH2Heading() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("## Subtitle"),
        [.heading(level: 2, text: "Subtitle")]
    )
}

func testH3PlusFallsToProse() {
    // v1 only supports # and ##; ### should NOT be a heading.
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("### h3"),
        [.prose("### h3")]
    )
}

func testHashWithoutSpaceIsNotHeading() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("#NotAHeading"),
        [.prose("#NotAHeading")]
    )
}

func testHeadingTextTrimsTrailingWhitespace() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("# Title   "),
        [.heading(level: 1, text: "Title")]
    )
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ChatMarkdownRendererTests`
Expected: 5 failures (all `parse` returns []).

- [ ] **Step 3: Implement heading parser**

Replace `parse(_:)` body in `ChatMarkdownRenderer.swift`:

```swift
static func parse(_ text: String) -> [Segment] {
    var segments: [Segment] = []
    let lines = text.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        let line = lines[i]
        if let heading = parseHeading(line: line) {
            segments.append(heading)
            i += 1
            continue
        }
        // Fallback: prose (single line for now; bullet/table/fence in later tasks).
        segments.append(.prose(line))
        i += 1
    }
    return segments
}

private static func parseHeading(line: String) -> Segment? {
    if line.hasPrefix("## ") {
        let body = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return .heading(level: 2, text: body)
    }
    if line.hasPrefix("# ") {
        let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return .heading(level: 1, text: body)
    }
    return nil
}
```

- [ ] **Step 4: Run tests, verify they pass**

Same command. Expected: 6/6 pass (1 from Task 1 + 5 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/ChatMarkdownRenderer.swift \
  Tests/NousTests/ChatMarkdownRendererTests.swift
git commit -m "feat(chat-md): heading parser (# / ##)"
```

---

## Task 3: Bullet block parser

**Files:**
- Modify: `Sources/Nous/Views/ChatMarkdownRenderer.swift`
- Modify: `Tests/NousTests/ChatMarkdownRendererTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `ChatMarkdownRendererTests`:

```swift
// MARK: - Bullets

func testSingleBullet() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("- one"),
        [.bulletBlock(["one"])]
    )
}

func testConsecutiveBulletsGroupIntoOneBlock() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("- one\n- two\n- three"),
        [.bulletBlock(["one", "two", "three"])]
    )
}

func testBulletBlockEndsOnNonBulletLine() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("- one\n- two\nNot a bullet"),
        [.bulletBlock(["one", "two"]), .prose("Not a bullet")]
    )
}

func testBulletWithoutSpaceIsProse() {
    // "-foo" without space after - is not a bullet.
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("-foo"),
        [.prose("-foo")]
    )
}

func testBulletContentTrimmed() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("-   indented bullet"),
        [.bulletBlock(["indented bullet"])]
    )
}
```

- [ ] **Step 2: Run tests, verify they fail**

Same command. Expected: 5 failures.

- [ ] **Step 3: Implement bullet block parser**

Update `parse(_:)` to detect bullet runs:

```swift
static func parse(_ text: String) -> [Segment] {
    var segments: [Segment] = []
    let lines = text.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        let line = lines[i]
        if let heading = parseHeading(line: line) {
            segments.append(heading)
            i += 1
            continue
        }
        if isBulletLine(line) {
            var bullets: [String] = []
            while i < lines.count, isBulletLine(lines[i]) {
                bullets.append(bulletContent(lines[i]))
                i += 1
            }
            segments.append(.bulletBlock(bullets))
            continue
        }
        segments.append(.prose(line))
        i += 1
    }
    return segments
}

private static func isBulletLine(_ line: String) -> Bool {
    // Must start with "- " (dash followed by at least one space).
    return line.hasPrefix("- ")
}

private static func bulletContent(_ line: String) -> String {
    return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
}
```

- [ ] **Step 4: Run tests, verify they pass**

Same command. Expected: 11/11 pass (6 prior + 5 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/ChatMarkdownRenderer.swift \
  Tests/NousTests/ChatMarkdownRendererTests.swift
git commit -m "feat(chat-md): bullet block parser"
```

---

## Task 4: Table parser (strict, pipe-bordered, split-then-validate)

**Files:**
- Modify: `Sources/Nous/Views/ChatMarkdownRenderer.swift`
- Modify: `Tests/NousTests/ChatMarkdownRendererTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `ChatMarkdownRendererTests`:

```swift
// MARK: - Tables

func testStandardTable() {
    let input = "| a | b |\n| --- | --- |\n| 1 | 2 |"
    XCTAssertEqual(
        ChatMarkdownRenderer.parse(input),
        [.table(headers: ["a", "b"], rows: [["1", "2"]])]
    )
}

func testTableTightSeparator() {
    let input = "| a | b |\n|---|---|\n| 1 | 2 |"
    XCTAssertEqual(
        ChatMarkdownRenderer.parse(input),
        [.table(headers: ["a", "b"], rows: [["1", "2"]])]
    )
}

func testTableAlignmentMarkersAccepted() {
    // v1 ignores alignment but must parse without rejection.
    let input = "| a | b |\n| :--- | ---: |\n| 1 | 2 |"
    XCTAssertEqual(
        ChatMarkdownRenderer.parse(input),
        [.table(headers: ["a", "b"], rows: [["1", "2"]])]
    )
}

func testTableMultipleDataRows() {
    let input = "| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |"
    XCTAssertEqual(
        ChatMarkdownRenderer.parse(input),
        [.table(headers: ["a", "b"], rows: [["1", "2"], ["3", "4"]])]
    )
}

func testTableWithoutSeparatorFallsToProse() {
    let input = "| a | b |\n| 1 | 2 |"
    let parsed = ChatMarkdownRenderer.parse(input)
    XCTAssertFalse(parsed.contains { if case .table = $0 { return true } else { return false } })
}

func testTableRaggedRowsNormalize() {
    // Row missing a cell gets right-padded; row with too many gets truncated.
    let input = "| a | b | c |\n| --- | --- | --- |\n| 1 | 2 |\n| 3 | 4 | 5 | 6 |"
    XCTAssertEqual(
        ChatMarkdownRenderer.parse(input),
        [.table(headers: ["a", "b", "c"], rows: [["1", "2", ""], ["3", "4", "5"]])]
    )
}

func testTableEscapedPipeIsLiteral() {
    let input = "| a | b |\n| --- | --- |\n| 1 \\| pipe | 2 |"
    XCTAssertEqual(
        ChatMarkdownRenderer.parse(input),
        [.table(headers: ["a", "b"], rows: [["1 | pipe", "2"]])]
    )
}

func testProsePipeDoesNotTriggerTable() {
    // Single prose line containing "|" is not a table candidate (no separator row).
    let input = "use cmd | grep foo"
    XCTAssertEqual(
        ChatMarkdownRenderer.parse(input),
        [.prose("use cmd | grep foo")]
    )
}

func testBorderlessGFMFallsToProse() {
    // v1 explicitly out of scope: no leading/trailing pipes.
    let input = "a | b\n--- | ---\n1 | 2"
    let parsed = ChatMarkdownRenderer.parse(input)
    XCTAssertFalse(parsed.contains { if case .table = $0 { return true } else { return false } })
}
```

- [ ] **Step 2: Run tests, verify they fail**

Same command. Expected: 9 failures.

- [ ] **Step 3: Implement table parser**

Add to `ChatMarkdownRenderer.swift` (place new helpers above `parse(_:)`, then call them inside `parse`):

```swift
private static let escapedPipeSentinel = "\u{0001}"  // ASCII SOH, won't appear in chat

private static func splitPipes(_ line: String) -> [String]? {
    // Returns nil if line is not pipe-bordered (no leading | or no trailing |).
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return nil }
    let escaped = trimmed.replacingOccurrences(of: "\\|", with: escapedPipeSentinel)
    var cells = escaped.components(separatedBy: "|")
    // Bordering pipes produce empty leading and trailing fields — drop them.
    if cells.first?.isEmpty == true { cells.removeFirst() }
    if cells.last?.isEmpty == true { cells.removeLast() }
    return cells.map {
        $0.replacingOccurrences(of: escapedPipeSentinel, with: "|")
            .trimmingCharacters(in: .whitespaces)
    }
}

private static func isSeparatorRow(_ line: String, expectedColumns: Int) -> Bool {
    guard let cells = splitPipes(line), cells.count == expectedColumns else { return false }
    let pattern = "^:?-+:?$"
    return cells.allSatisfy { $0.range(of: pattern, options: .regularExpression) != nil }
}

private static func parseTable(lines: [String], startIndex: Int) -> (Segment, Int)? {
    // Returns the table segment and the index of the next non-table line, or nil if not a table.
    guard startIndex + 1 < lines.count,
          let headers = splitPipes(lines[startIndex]),
          headers.count >= 2 else { return nil }
    guard isSeparatorRow(lines[startIndex + 1], expectedColumns: headers.count) else { return nil }

    var rows: [[String]] = []
    var i = startIndex + 2
    while i < lines.count, var cells = splitPipes(lines[i]) {
        // Normalize column count to header count.
        if cells.count < headers.count {
            cells.append(contentsOf: Array(repeating: "", count: headers.count - cells.count))
        } else if cells.count > headers.count {
            cells = Array(cells.prefix(headers.count))
        }
        rows.append(cells)
        i += 1
    }
    guard !rows.isEmpty else { return nil }
    return (.table(headers: headers, rows: rows), i)
}
```

Update `parse(_:)` to try table before prose:

```swift
static func parse(_ text: String) -> [Segment] {
    var segments: [Segment] = []
    let lines = text.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        let line = lines[i]
        if let heading = parseHeading(line: line) {
            segments.append(heading)
            i += 1
            continue
        }
        if isBulletLine(line) {
            var bullets: [String] = []
            while i < lines.count, isBulletLine(lines[i]) {
                bullets.append(bulletContent(lines[i]))
                i += 1
            }
            segments.append(.bulletBlock(bullets))
            continue
        }
        if let (tableSegment, nextIndex) = parseTable(lines: lines, startIndex: i) {
            segments.append(tableSegment)
            i = nextIndex
            continue
        }
        segments.append(.prose(line))
        i += 1
    }
    return segments
}
```

- [ ] **Step 4: Run tests, verify they pass**

Same command. Expected: 20/20 pass (11 prior + 9 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/ChatMarkdownRenderer.swift \
  Tests/NousTests/ChatMarkdownRendererTests.swift
git commit -m "feat(chat-md): table parser (pipe-bordered, split-then-validate)"
```

---

## Task 5: Code fence (verbatim) + unclosed fence fallback

**Files:**
- Modify: `Sources/Nous/Views/ChatMarkdownRenderer.swift`
- Modify: `Tests/NousTests/ChatMarkdownRendererTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `ChatMarkdownRendererTests`:

```swift
// MARK: - Code fences

func testClosedFenceProducesVerbatim() {
    let input = "```\nint *p = `foo`;\n```"
    XCTAssertEqual(
        ChatMarkdownRenderer.parse(input),
        [.verbatim("int *p = `foo`;")]
    )
}

func testClosedFenceMultilineContent() {
    let input = "```\nline1\nline2\nline3\n```"
    XCTAssertEqual(
        ChatMarkdownRenderer.parse(input),
        [.verbatim("line1\nline2\nline3")]
    )
}

func testFenceContentNotSanitized() {
    // **bold** and *italic* inside fence must survive.
    let input = "```\n**bold**\n*italic*\n```"
    XCTAssertEqual(
        ChatMarkdownRenderer.parse(input),
        [.verbatim("**bold**\n*italic*")]
    )
}

func testUnclosedFenceFallsBackToProseAndStructure() {
    // Bare ``` line is prose; captured content re-fed to normal parsing.
    let input = "```\nint *p\n# Header\n- bullet"
    XCTAssertEqual(
        ChatMarkdownRenderer.parse(input),
        [
            .prose("```"),
            .prose("int *p"),
            .heading(level: 1, text: "Header"),
            .bulletBlock(["bullet"])
        ]
    )
}

func testFenceWithLanguageTagStillVerbatim() {
    // ```swift opens a fence; language tag is dropped, content captured.
    let input = "```swift\nlet x = 1\n```"
    XCTAssertEqual(
        ChatMarkdownRenderer.parse(input),
        [.verbatim("let x = 1")]
    )
}
```

- [ ] **Step 2: Run tests, verify they fail**

Same command. Expected: 5 failures.

- [ ] **Step 3: Implement fence parser**

Add helper above `parse(_:)`:

```swift
private static func isFenceOpen(_ line: String) -> Bool {
    // Triple backtick at line start, possibly followed by language tag.
    return line.hasPrefix("```")
}

/// Returns either (verbatim segment, indexAfterClosingFence) on closed fence,
/// or nil if the fence is unclosed (caller falls back to re-parsing).
private static func parseFence(lines: [String], startIndex: Int) -> (Segment, Int)? {
    guard startIndex < lines.count, isFenceOpen(lines[startIndex]) else { return nil }
    var captured: [String] = []
    var i = startIndex + 1
    while i < lines.count {
        if lines[i].hasPrefix("```") {
            // Closing fence found.
            return (.verbatim(captured.joined(separator: "\n")), i + 1)
        }
        captured.append(lines[i])
        i += 1
    }
    // Reached EOF without closing fence — caller handles fallback.
    return nil
}
```

Update `parse(_:)` to handle fences with unclosed-fallback:

```swift
static func parse(_ text: String) -> [Segment] {
    var segments: [Segment] = []
    let lines = text.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        let line = lines[i]

        // Try fence first (must be checked before prose fallback).
        if isFenceOpen(line) {
            if let (verbatim, nextIndex) = parseFence(lines: lines, startIndex: i) {
                segments.append(verbatim)
                i = nextIndex
                continue
            } else {
                // Unclosed fence: bare ``` line as prose; re-parse captured content
                // with the same parser (Recursion-free: just continue past the ``` line.
                // Subsequent lines hit the normal parsing loop below.)
                segments.append(.prose(line))
                i += 1
                continue
            }
        }

        if let heading = parseHeading(line: line) {
            segments.append(heading)
            i += 1
            continue
        }
        if isBulletLine(line) {
            var bullets: [String] = []
            while i < lines.count, isBulletLine(lines[i]) {
                bullets.append(bulletContent(lines[i]))
                i += 1
            }
            segments.append(.bulletBlock(bullets))
            continue
        }
        if let (tableSegment, nextIndex) = parseTable(lines: lines, startIndex: i) {
            segments.append(tableSegment)
            i = nextIndex
            continue
        }
        segments.append(.prose(line))
        i += 1
    }
    return segments
}
```

The unclosed-fence fallback is naturally correct: when `parseFence` returns nil, we emit the bare `` ``` `` as prose and continue the main loop on `i + 1`. The captured content lines (which were never consumed) get re-parsed normally — `# Header` becomes a heading, `- bullet` becomes a bullet block, etc. No recursion needed.

- [ ] **Step 4: Run tests, verify they pass**

Same command. Expected: 25/25 pass (20 prior + 5 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/ChatMarkdownRenderer.swift \
  Tests/NousTests/ChatMarkdownRendererTests.swift
git commit -m "feat(chat-md): code fence (verbatim) + unclosed-fence fallback"
```

---

## Task 6: Prose sanitization (balanced asterisk/backtick + line-start prefixes)

**Files:**
- Modify: `Sources/Nous/Views/ChatMarkdownRenderer.swift`
- Modify: `Tests/NousTests/ChatMarkdownRendererTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `ChatMarkdownRendererTests`:

```swift
// MARK: - Sanitization (balanced pairs only, no underscores)

func testBoldStripped() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("**bold** text"),
        [.prose("bold text")]
    )
}

func testItalicAsteriskStripped() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("*italic* text"),
        [.prose("italic text")]
    )
}

func testInlineCodeStripped() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("use `cmd` here"),
        [.prose("use cmd here")]
    )
}

func testOrderedListPrefixStripped() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("1. first\n2. second"),
        [.prose("first"), .prose("second")]
    )
}

func testQuotePrefixStripped() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("> quoted"),
        [.prose("quoted")]
    )
}

// Preservation cases — must NOT be touched

func testUnbalancedAsteriskPreserved() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("int *p = NULL"),
        [.prose("int *p = NULL")]
    )
}

func testWildcardAsteriskPreserved() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("rg '*.swift'"),
        [.prose("rg '*.swift'")]
    )
}

func testMultiplicationPreserved() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("3 * 4 = 12"),
        [.prose("3 * 4 = 12")]
    )
}

func testUnderscoreItalicPreserved() {
    // v1 explicitly does not strip underscores.
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("snake_case_var"),
        [.prose("snake_case_var")]
    )
}

func testDoubleUnderscorePreserved() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("__init__ method"),
        [.prose("__init__ method")]
    )
}

func testUnbalancedBacktickPreserved() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("the ` symbol alone"),
        [.prose("the ` symbol alone")]
    )
}

func testHeadingTextNotSanitized() {
    // Sanitization applies only to prose segments, not heading text.
    // (Heading content rarely needs sanitization in practice; documenting current behavior.)
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("# **bold** title"),
        [.heading(level: 1, text: "**bold** title")]
    )
}

func testBulletContentSanitized() {
    XCTAssertEqual(
        ChatMarkdownRenderer.parse("- **item**"),
        [.bulletBlock(["item"])]
    )
}
```

- [ ] **Step 2: Run tests, verify they fail**

Same command. Expected: 13 failures (sanitization not yet wired).

- [ ] **Step 3: Implement sanitization**

Add helper above `parse(_:)`:

```swift
private static let boldPairRegex = try! NSRegularExpression(pattern: #"\*\*([^\*]+)\*\*"#)
private static let italicAsteriskRegex = try! NSRegularExpression(
    pattern: #"(?<!\*)\*([^\*\s][^\*]*?)\*(?!\*)"#
)
private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
private static let orderedListPrefixRegex = try! NSRegularExpression(pattern: #"^\d+\.\s+"#)
private static let quotePrefixRegex = try! NSRegularExpression(pattern: #"^>\s+"#)

/// Strips unsupported markdown delimiters from a single line of prose.
/// Underscores are NEVER touched (preserves snake_case_var, __init__).
private static func sanitizeProse(_ line: String) -> String {
    var result = line

    // Line-start prefixes first (always strip).
    result = applyRegex(orderedListPrefixRegex, to: result, replacement: "")
    result = applyRegex(quotePrefixRegex, to: result, replacement: "")

    // Balanced-pair stripping.
    result = applyRegex(boldPairRegex, to: result, replacement: "$1")
    result = applyRegex(italicAsteriskRegex, to: result, replacement: "$1")
    result = applyRegex(inlineCodeRegex, to: result, replacement: "$1")

    return result
}

private static func applyRegex(
    _ regex: NSRegularExpression,
    to input: String,
    replacement: String
) -> String {
    let range = NSRange(input.startIndex..., in: input)
    return regex.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
}
```

Apply sanitization in `parse(_:)` — modify the prose-emission and bullet-content paths to call `sanitizeProse`:

```swift
// In the bullet branch, change:
//     bullets.append(bulletContent(lines[i]))
// to:
//     bullets.append(sanitizeProse(bulletContent(lines[i])))

// In the prose fallback, change:
//     segments.append(.prose(line))
// to:
//     segments.append(.prose(sanitizeProse(line)))
//
// (Apply the sanitize to BOTH the unclosed-fence prose emission for the bare ``` line
//  AND the regular prose fallback at the end of the loop.)
```

Concretely, the updated `parse(_:)`:

```swift
static func parse(_ text: String) -> [Segment] {
    var segments: [Segment] = []
    let lines = text.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        let line = lines[i]

        if isFenceOpen(line) {
            if let (verbatim, nextIndex) = parseFence(lines: lines, startIndex: i) {
                segments.append(verbatim)
                i = nextIndex
                continue
            } else {
                segments.append(.prose(sanitizeProse(line)))
                i += 1
                continue
            }
        }
        if let heading = parseHeading(line: line) {
            segments.append(heading)
            i += 1
            continue
        }
        if isBulletLine(line) {
            var bullets: [String] = []
            while i < lines.count, isBulletLine(lines[i]) {
                bullets.append(sanitizeProse(bulletContent(lines[i])))
                i += 1
            }
            segments.append(.bulletBlock(bullets))
            continue
        }
        if let (tableSegment, nextIndex) = parseTable(lines: lines, startIndex: i) {
            segments.append(tableSegment)
            i = nextIndex
            continue
        }
        segments.append(.prose(sanitizeProse(line)))
        i += 1
    }
    return segments
}
```

- [ ] **Step 4: Run tests, verify they pass**

Same command. Expected: 38/38 pass (25 prior + 13 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/ChatMarkdownRenderer.swift \
  Tests/NousTests/ChatMarkdownRendererTests.swift
git commit -m "feat(chat-md): prose sanitization (balanced asterisk/backtick + line prefixes)"
```

---

## Task 7: SwiftUI view (`ChatMarkdownView`) rendering segments

**Files:**
- Modify: `Sources/Nous/Views/ChatMarkdownRenderer.swift`

This task adds the SwiftUI view that consumes `[Segment]` and renders it. SwiftUI view unit tests are not pursued here (high friction in XCTest, low value for this code) — correctness is verified via existing parser tests, the build, and the manual live test in Task 13.

- [ ] **Step 1: Add `ChatMarkdownView` struct**

Append to `Sources/Nous/Views/ChatMarkdownRenderer.swift`:

```swift
struct ChatMarkdownView: View {

    let segments: [Segment]

    private let bodyFont: Font = .system(size: 14, weight: .regular)
    private let h1Font: Font = .system(size: 16, weight: .semibold)
    private let h2Font: Font = .system(size: 15, weight: .semibold)
    private let bodyLineSpacing: CGFloat = 8
    private let segmentSpacing: CGFloat = 14
    private let bulletIndent: CGFloat = 4
    private let bulletGap: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: segmentSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                segmentView(segment)
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: Segment) -> some View {
        switch segment {
        case .heading(let level, let text):
            Text(text)
                .font(level == 1 ? h1Font : h2Font)
                .foregroundColor(AppColor.colaDarkText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .bulletBlock(let bullets):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                    HStack(alignment: .firstTextBaseline, spacing: bulletGap) {
                        Text("•")
                            .font(bodyFont)
                            .foregroundColor(AppColor.colaDarkText)
                        Text(bullet)
                            .font(bodyFont)
                            .foregroundColor(AppColor.colaDarkText)
                            .lineSpacing(bodyLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, bulletIndent)
                }
            }

        case .table(let headers, let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Text(header)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppColor.colaDarkText)
                            .textSelection(.enabled)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(bodyFont)
                                .foregroundColor(AppColor.colaDarkText)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

        case .prose(let text):
            Text(text)
                .font(bodyFont)
                .foregroundColor(AppColor.colaDarkText)
                .lineSpacing(bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .verbatim(let text):
            Text(text)
                .font(bodyFont)
                .foregroundColor(AppColor.colaDarkText)
                .lineSpacing(bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
```

`ChatMarkdownRenderer` (the parser namespace) and `ChatMarkdownView` (the rendering view) co-exist in the same file. Naming separates the two responsibilities.

- [ ] **Step 2: Verify build**

Run: `xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build`
Expected: Build succeeds. No new warnings about `ChatMarkdownView` or `Grid` unavailability (Nous targets macOS 13+ per existing code; verify deployment target if `Grid` warns).

- [ ] **Step 3: Run all renderer tests**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ChatMarkdownRendererTests`
Expected: 38/38 pass (no test changes; sanity check that view code compiles cleanly).

- [ ] **Step 4: Commit**

```bash
git add Sources/Nous/Views/ChatMarkdownRenderer.swift
git commit -m "feat(chat-md): ChatMarkdownView renders Segment values to SwiftUI"
```

---

## Task 8: MessageBubble refactor — AssistantBubbleContent helper

**Files:**
- Modify: `Sources/Nous/Views/ChatArea.swift` (lines 532–611)

- [ ] **Step 1: Read current `MessageBubble` shape**

Re-read lines 532–611 to confirm the property names and modifier order. The existing structure:

- `paragraphTexts: [String]` computed property — runs `ClarificationCardParser.parse` (assistant) or treats text as user input, then calls `normalizedParagraphs`.
- `body` switches on `isUser` and `ForEach`-renders paragraphs.
- `.animation(.easeOut(duration: 0.15), value: paragraphTexts)` on the assistant `HStack`.
- `normalizedParagraphs(from:)` private static helper.

- [ ] **Step 2: Refactor `MessageBubble`**

Replace the existing `private var paragraphTexts: [String]` and the `body` `else` branch (assistant path) with the split design.

Concretely, in `Sources/Nous/Views/ChatArea.swift`:

Replace:

```swift
private var paragraphTexts: [String] {
    let parsed = isUser
        ? ClarificationContent(displayText: text, card: nil, keepsQuickActionMode: false)
        : ClarificationCardParser.parse(text)

    return Self.normalizedParagraphs(from: parsed.displayText)
}
```

With:

```swift
private var userParagraphTexts: [String] {
    Self.normalizedParagraphs(from: text)
}

private var assistantDisplayText: String {
    ClarificationCardParser.parse(text).displayText
}
```

Replace the `body` `else` branch (assistant rendering, lines around 575–593) with:

```swift
} else {
    HStack {
        AssistantBubbleContent(displayText: assistantDisplayText)
        Spacer(minLength: 0)
    }
}
```

Replace the `if isUser` branch's `ForEach` to use `userParagraphTexts`:

```swift
if isUser {
    HStack {
        Spacer(minLength: 60)
        VStack(alignment: .leading, spacing: userParagraphSpacing) {
            ForEach(Array(userParagraphTexts.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(AppColor.colaDarkText)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppColor.colaBubble)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
```

Also update the outer guard `if !paragraphTexts.isEmpty` (around line 556). Replace with two parallel checks — the assistant path always renders (even empty `assistantDisplayText` produces zero segments, which is harmless), so simplify to:

```swift
let hasContent = isUser ? !userParagraphTexts.isEmpty : !assistantDisplayText.isEmpty
if hasContent {
    if isUser {
        // ... user branch as above ...
    } else {
        // ... assistant branch with AssistantBubbleContent ...
    }
}
```

Add the `AssistantBubbleContent` helper view at the bottom of `ChatArea.swift` (sibling of `MessageBubble`):

```swift
private struct AssistantBubbleContent: View {
    let displayText: String

    private let assistantTextMaxWidth: CGFloat = 690

    var body: some View {
        // Single parse per body recompute via Swift `let` binding.
        let segments = ChatMarkdownRenderer.parse(displayText)
        return ChatMarkdownView(segments: segments)
            .frame(maxWidth: assistantTextMaxWidth, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .animation(.easeOut(duration: 0.15), value: segments.count)
    }
}
```

`assistantTextMaxWidth` moves from `MessageBubble` into the helper view (the value 690 is preserved).

`normalizedParagraphs(from:)` stays as a `MessageBubble` private static helper, used only by `userParagraphTexts`.

- [ ] **Step 3: Verify build**

Run: `xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build`
Expected: Build succeeds.

- [ ] **Step 4: Run full test suite**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'`
Expected: All existing tests + the new renderer tests pass. No regression.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Views/ChatArea.swift
git commit -m "refactor(chat): MessageBubble split + AssistantBubbleContent helper for single-parse markdown render"
```

---

## Task 9: BrainstormAgent — bullet hybrid constraint

**Files:**
- Modify: `Sources/Nous/Models/Agents/BrainstormAgent.swift`
- Modify: `Tests/NousTests/QuickActionAgentsTests.swift`

- [ ] **Step 1: Write failing test**

Append to `BrainstormAgentTests` in `QuickActionAgentsTests.swift` (find the existing class; if absent, the file likely groups tests as `DirectionAgentTests`, `BrainstormAgentTests`, `PlanAgentTests`):

```swift
func testContextAddendumOnTurnOneRequiresShortLabelTradeoffPlusProseJudgment() {
    let addendum = agent.contextAddendum(turnIndex: 1)
    XCTAssertNotNil(addendum)
    let body = addendum!
    XCTAssertTrue(body.contains("短 label"), "addendum must require short labels")
    XCTAssertTrue(body.contains("trade-off"), "addendum must mention trade-off")
    XCTAssertTrue(body.contains("非 bullet") || body.contains("唔用 bullet"),
                  "addendum must require non-bullet judgment prose")
    XCTAssertTrue(body.contains("等权") == false ||
                  body.contains("唔可以等权列 options") || body.contains("唔可以系完整段落"),
                  "addendum must guard against equally-weighted options listicle")
}
```

(Adjust `agent` reference to match the existing test class's instance variable.)

- [ ] **Step 2: Run test, verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/QuickActionAgentsTests`
Expected: New test fails (current addendum doesn't contain these strings).

- [ ] **Step 3: Update BrainstormAgent**

Replace `BrainstormAgent.contextAddendum` body (currently returns at turn 1+):

```swift
func contextAddendum(turnIndex: Int) -> String? {
    guard turnIndex >= 1 else { return nil }
    return """
    ---

    BRAINSTORM MODE PRODUCTION CONTRACT:
    Alex has answered the opening question. Your job is divergent.
    Generate genuinely distinct directions, surface the pattern behind them, and
    call out which feel alive vs which are probably noise. Do NOT narrow to a single
    answer.

    格式：用 `-` bullet 列出 distinct directions，每条 bullet 系**短 label + 一句 trade-off**
    （唔可以系完整段落），跟住一段**唔用 bullet 嘅 prose** 拆边样 feel alive、边样系噪音。
    Bullet block 唔可以等权列 options——读者一眼睇到嘅唔系「四个并列选项」，
    而系「四条方向加一段判断」。

    Bias prevention: this turn intentionally runs without personal-memory layers
    (no userModel, no evidence, no project context, no project goal, no recent
    conversations, no RAG, no judge inference, no behavior profile).
    Lean into novelty rather than what you would assume Alex prefers from past chats.
    """
}
```

- [ ] **Step 4: Run test, verify it passes**

Same command. Expected: All Brainstorm tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Models/Agents/BrainstormAgent.swift \
  Tests/NousTests/QuickActionAgentsTests.swift
git commit -m "feat(brainstorm): bullet+tradeoff format with non-bullet prose judgment"
```

---

## Task 10: PlanAgent — cap-aware switch with 3 addendums + range pattern

**Files:**
- Modify: `Sources/Nous/Models/Agents/PlanAgent.swift`
- Modify: `Tests/NousTests/QuickActionAgentsTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `PlanAgentTests`:

```swift
// MARK: - Cap-aware contextAddendum

func testAddendumTurnZeroIsNil() {
    XCTAssertNil(agent.contextAddendum(turnIndex: 0))
}

func testAddendumTurnOneIsDecideOrAsk() {
    let addendum = agent.contextAddendum(turnIndex: 1)
    XCTAssertNotNil(addendum)
    XCTAssertTrue(addendum!.contains("DECIDE OR ASK"))
}

func testAddendumTurnTwoIsNormalProductionWithFormatScaffold() {
    let addendum = agent.contextAddendum(turnIndex: 2)
    XCTAssertNotNil(addendum)
    XCTAssertTrue(addendum!.contains("PLAN MODE PRODUCTION CONTRACT"))
    XCTAssertTrue(addendum!.contains("# Outcome"))
    XCTAssertTrue(addendum!.contains("# Weekly schedule"))
    XCTAssertTrue(addendum!.contains("| 周 |"))
    XCTAssertTrue(addendum!.contains("# Where you'll stall"))
    XCTAssertTrue(addendum!.contains("# Today's first step"))
}

func testAddendumTurnThreeIsAlsoNormalProduction() {
    let addendum = agent.contextAddendum(turnIndex: 3)
    XCTAssertNotNil(addendum)
    XCTAssertTrue(addendum!.contains("PLAN MODE PRODUCTION CONTRACT"))
}

func testAddendumAtCapIsFinalUrgent() {
    // maxClarificationTurns = 4 currently.
    let addendum = agent.contextAddendum(turnIndex: 4)
    XCTAssertNotNil(addendum)
    XCTAssertTrue(addendum!.contains("FINAL TURN"))
    XCTAssertTrue(addendum!.contains("# Outcome"))
    XCTAssertTrue(addendum!.contains("# Weekly schedule"))
    XCTAssertFalse(addendum!.contains("PLAN MODE PRODUCTION CONTRACT"),
                   "cap turn must use FINAL urgent variant, not normal production")
}

func testAddendumPastCapStillFinalUrgent_DefensiveRange() {
    // Range pattern Self.maxClarificationTurns... must catch turn 5, 6, ...
    for turn in [5, 6, 10] {
        let addendum = agent.contextAddendum(turnIndex: turn)
        XCTAssertNotNil(addendum, "turn \(turn) should have addendum")
        XCTAssertTrue(addendum!.contains("FINAL TURN"),
                      "turn \(turn) should use FINAL urgent (defensive range)")
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Same command (only-testing PlanAgentTests if scoped, else QuickActionAgentsTests). Expected: 6 failures.

- [ ] **Step 3: Update PlanAgent**

Replace the entire body of `PlanAgent.contextAddendum(turnIndex:)`:

```swift
func contextAddendum(turnIndex: Int) -> String? {
    switch turnIndex {
    case 0:
        return nil
    case 1:
        return Self.decideOrAskAddendum
    case Self.maxClarificationTurns...:
        return Self.finalUrgentAddendum
    default:
        return Self.normalProductionAddendum
    }
}

private static let decideOrAskAddendum = """
---

PLAN MODE — DECIDE OR ASK CONTRACT:
Alex has answered your opening question. Either:
(a) produce the structured plan now if you have enough on outcome, timeframe,
    and his real capacity, OR
(b) ask exactly one more open-ended question if a critical piece is still missing.
If you ask, keep the <phase>understanding</phase> marker.
If you produce the plan, drop the marker.
"""

private static let normalProductionAddendum = """
---

PLAN MODE PRODUCTION CONTRACT:
Produce a structured plan using these markdown sections:

# Outcome
（one short paragraph — the actual outcome Alex is chasing, not the surface activity）

# Weekly schedule
| 周 | 重点 | 具体动作 |
|---|---|---|
| Week 1 | ... | ... |

# Where you'll stall
- ...
- ...

# Today's first step
（one concrete action）

Use what you know about Alex from prior conversations and stored memory.
Stay specific. No generic productivity advice.
Drop the <phase>understanding</phase> marker once you commit to the plan.
"""

private static let finalUrgentAddendum = """
---

PLAN MODE — FINAL TURN:
This is your last chance to produce the plan. Mode drops after this reply.
You may NOT ask another clarifying question. Output the four markdown sections
now using whatever you have learned so far:

# Outcome
# Weekly schedule (use the | table | format)
# Where you'll stall
# Today's first step

Drop the <phase>understanding</phase> marker. Stay specific.
"""
```

`turnDirective` is unchanged — still returns `.complete` when `turnIndex >= Self.maxClarificationTurns`. The cap-aware addendum is a pre-execution belt-and-suspenders on top of the existing post-execution mode-drop.

- [ ] **Step 4: Run tests, verify they pass**

Same command. Expected: 6 new tests pass + existing PlanAgent tests still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Nous/Models/Agents/PlanAgent.swift \
  Tests/NousTests/QuickActionAgentsTests.swift
git commit -m "feat(plan): cap-aware contextAddendum (decide-or-ask / normal / FINAL urgent at range)"
```

---

## Task 11: ChatViewModel.assembleContext — chat format policy volatile piece

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift` (around line 920)

This task has minimal new test surface — the existing `assembleContext` is not unit-tested via output-string assertions in the codebase (it's a long composition). We add one targeted assertion test to confirm the policy lands in the volatile output.

- [ ] **Step 1: Write a focused test**

Check whether `Tests/NousTests/` has any test file that exercises `ChatViewModel.assembleContext`. Search:

Run: `grep -rn "assembleContext" Tests/NousTests/ | head -5`
Expected: Find existing test file(s) that call `assembleContext`, or zero results.

If a test file exists, append to it. If not, create `Tests/NousTests/ChatFormatPolicyTests.swift`:

```swift
import XCTest
@testable import Nous

final class ChatFormatPolicyTests: XCTestCase {

    func testAssembleContextIncludesChatFormatPolicy() async throws {
        // Use minimal arguments — `assembleContext` is a static factory that
        // returns a context string. Pass empty/no-op values where possible.
        // (Adjust to actual signature; the call below is a template.)
        let result = ChatViewModel.assembleContext(
            anchor: "",
            chatMode: .plain,
            currentUserInput: "test",
            recentMessages: [],
            citations: [],
            globalMemory: nil,
            essentialStory: nil,
            userModel: nil,
            memoryEvidence: [],
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            projectGoal: nil,
            contradictionRecall: [],
            judgeFocus: nil,
            behaviorProfileBlock: nil,
            activeQuickActionMode: nil,
            quickActionAddendum: nil,
            allowInteractiveClarification: false,
            now: Date()
        )
        XCTAssertTrue(result.contains("CHAT FORMAT POLICY"),
                      "assembleContext must include the chat format policy block")
        XCTAssertTrue(result.contains("`# 标题`"),
                      "policy must list markdown structure tokens")
        XCTAssertTrue(result.contains("「」"),
                      "policy must reference 「」 emphasis convention")
    }
}
```

**Note for the implementer:** the exact `assembleContext` parameter list in `Sources/Nous/ViewModels/ChatViewModel.swift:812` defines the signature. Read that signature first and align the test call. The above is a template — adjust labels and types to match. If the signature requires more values than convenient, factor out the policy assertion into an alternative test that calls a smaller helper, OR add a Swift `internal` accessor that returns the policy string for testing.

- [ ] **Step 2: Run test, verify it fails**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ChatFormatPolicyTests`
Expected: FAIL — policy not yet inserted.

- [ ] **Step 3: Insert format policy into `assembleContext`**

In `Sources/Nous/ViewModels/ChatViewModel.swift`, locate the `assembleContext` static function (around line 812). Find where `volatilePieces` is initialized (search `volatilePieces`).

At the **start** of the volatile-pieces composition (before any other `volatilePieces.append(...)` call within the function), insert:

```swift
volatilePieces.append("""
---

CHAT FORMAT POLICY:
当内容有 distinct items / 周期 schedule / 数据对比，可以用 markdown 结构（`# 标题`、
`- bullet`、`| table |`）呈现。Emphasis 仍然用「」，唔好用 `**bold**` / `*italic*` / 倒勾。
""")
```

Placement rationale: this is a global format policy independent of mode. Earlier-in-context instructions get more weight from the LLM. Pre-pending to volatile (after stable anchor.md but before any memory / citations / quick-action addendum) gives it the right priority.

- [ ] **Step 4: Run test, verify it passes**

Same command. Expected: PASS.

- [ ] **Step 5: Run full test suite to confirm no regression**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Nous/ViewModels/ChatViewModel.swift \
  Tests/NousTests/ChatFormatPolicyTests.swift
git commit -m "feat(chat): chat format policy in assembleContext volatile layer (4 modes)"
```

---

## Task 12: ClarificationCardParser <summary> + markdown integration test

**Files:**
- Modify: `Tests/NousTests/ClarificationCardParserTests.swift`

This task is a **regression guard test only** — no source changes expected. The existing `ClarificationCardParser` already preserves inner content of `<summary>` blocks (per spec context); this test confirms downstream chat markdown rendering will see structured markdown intact.

- [ ] **Step 1: Add test**

Append to `Tests/NousTests/ClarificationCardParserTests.swift`:

```swift
func testSummaryWithInnerMarkdownPreservesStructure() {
    let input = """
    Here is the summary:

    <summary>
    # Title

    - bullet 1
    - bullet 2

    | col | col |
    |---|---|
    | 1 | 2 |
    </summary>

    More text after.
    """
    let parsed = ClarificationCardParser.parse(input)
    let display = parsed.displayText

    // Markdown structure inside <summary> must survive parsing intact.
    XCTAssertTrue(display.contains("# Title"), "heading preserved")
    XCTAssertTrue(display.contains("- bullet 1"), "bullets preserved")
    XCTAssertTrue(display.contains("| col | col |"), "table header preserved")
    XCTAssertTrue(display.contains("|---|---|"), "table separator preserved")

    // Tag markers must be stripped.
    XCTAssertFalse(display.contains("<summary>"), "<summary> tag stripped")
    XCTAssertFalse(display.contains("</summary>"), "</summary> tag stripped")
}
```

- [ ] **Step 2: Run test**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ClarificationCardParserTests`
Expected: PASS without source changes.

If FAIL: investigate `ClarificationCardParser.parse` — the spec assumed inner markdown is preserved. If it's not, the parser needs a small fix to preserve newlines / structure inside `<summary>`. Implement the fix as part of this task and re-run.

- [ ] **Step 3: Commit**

```bash
git add Tests/NousTests/ClarificationCardParserTests.swift
# Plus Sources/Nous/Services/ClarificationCardParser.swift if changes were needed.
git commit -m "test(parser): regression guard for <summary> + inner markdown preservation"
```

---

## Task 13: Full-suite test run + manual live test

**Files:** None (verification only).

- [ ] **Step 1: Full test suite**

Run: `xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'`
Expected: All tests pass (existing + new from tasks 1–12).

If anything fails, fix the failure before proceeding. Do not move to manual live test until the suite is green.

- [ ] **Step 2: Build app**

Run: `xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build`
Expected: Build succeeds.

- [ ] **Step 3: Launch the macOS app**

Open the built `.app` from `~/Library/Developer/Xcode/DerivedData/Nous-*/Build/Products/Debug/Nous.app`, or via Xcode's Run command targeting macOS.

- [ ] **Step 4: Live test — Plan mode (golden path)**

1. Open a fresh chat conversation in Nous.
2. Click the **Plan** quick action.
3. Reply to the opening question with: 我想开始跑步训练
4. Continue answering substantively (state of legs, time available, weekly frequency, target outcome).
5. **Verify** the assistant produces a reply containing:
   - `# Outcome` heading rendered as larger weighted text
   - `# Weekly schedule` heading + a `|...|` table rendered as a real grid (rows visible, columns aligned)
   - `# Where you'll stall` heading + bullet list rendered with bullet glyphs
   - `# Today's first step` heading + a concrete action paragraph

Pass = all four sections visibly structured. Fail = any section appears as raw `# Heading` text or bullets appear as `- bullet` literal text.

- [ ] **Step 5: Live test — Plan cap behavior**

1. Open another fresh Plan conversation.
2. Reply vaguely / withhold information across 4+ turns to provoke the cap.
3. **Verify** at the cap turn (turn 4):
   - The assistant produces the structured plan output (4 sections), not another clarifying question.
   - No duplicate assistant replies in the same turn.
   - The `<phase>understanding</phase>` marker is gone from the rendered output.

- [ ] **Step 6: Live test — Brainstorm mode**

1. Open a fresh chat, click **Brainstorm**.
2. Reply: 我 startup 应该 pivot 边度
3. **Verify** the assistant produces:
   - A `-` bullet list with short label + tradeoff per bullet (each bullet ≤ 1 sentence)
   - A non-bullet prose paragraph after the bullets analyzing alive vs noise
   - Bullets do NOT look like equally-weighted options (no Direction-style enumeration)

- [ ] **Step 7: Live test — Direction mode (regression check)**

1. Open a fresh chat, click **Direction**.
2. Ask any question requiring a single next step.
3. **Verify**:
   - Assistant reply is prose-dominant, convergent, narrows to one concrete next step.
   - No regression into a bullet list of equally-weighted options.

- [ ] **Step 8: Live test — Default chat mode (table)**

1. Open a fresh default chat (no quick action).
2. Ask: 比较 swift concurrency 同 dispatch queue
3. **Verify** the reply contains a `|...|` comparison table that renders as a grid.

- [ ] **Step 9: Live test — marker leak check**

Across all four conversations above:
- **Verify** no `<phase>understanding</phase>` or `<summary>` raw tag appears in any chat bubble.
- **Verify** no raw `**`, `*`, or `` ` `` characters are visible in places that would suggest unstripped balanced markdown.
- **Verify** technical examples like `int *p` (if they appear) are preserved literally with the asterisk visible.

- [ ] **Step 10: Decision gate**

If all live tests pass: **Phase 1 hard gate is released.** Proceed to memory housekeeping (Task 14) and report completion.

If any live test reveals a regression: do not commit further. Report the specific failure (mode + what was expected vs observed) and either fix in this branch or escalate to the deferred true-synthetic-final-turn (option C from spec).

---

## Task 14: Memory housekeeping (post-ship, only after Task 13 passes)

**Files:** Outside the repo — `~/.claude/projects/-Users-kochunlong-Library-Mobile-Documents-com-apple-CloudDocs-Nous-archive/memory/`

These are agent-memory updates that persist across conversations. No git commit.

- [ ] **Step 1: Update `feedback_no_markdown_bold_in_chat.md`**

Read: `~/.claude/projects/-Users-kochunlong-Library-Mobile-Documents-com-apple-CloudDocs-Nous-archive/memory/feedback_no_markdown_bold_in_chat.md`

Replace the body to remove the stale "STYLE RULES" claim and add the post-ship status:

```markdown
---
name: Chat format policy
description: Markdown structure permitted in chat bubbles (headers / bullets / tables); emphasis still uses 「」; never `**bold**` or `*italic*`
type: feedback
---

Chat bubbles render markdown headers (`#`, `##`), unordered bullets (`-`), and pipe-bordered tables (`| col | col |`). Other markdown (bold, italic, ordered list, inline code) is sanitized to plain text. Underscores are never touched (preserves `snake_case_var`, `__init__`).

**Why:** 2026-04-26 Plan-fix shipped — chat format policy lives in `ChatViewModel.assembleContext` volatile layer (NOT in anchor.md, which is frozen per `AGENTS.md:39, 131`). Renderer is `ChatMarkdownRenderer` + `ChatMarkdownView` in `Sources/Nous/Views/ChatMarkdownRenderer.swift`.

**How to apply:** When suggesting prompt or anchor changes for emphasis / formatting, target the volatile policy in `assembleContext`, not anchor.md. When debugging missing markdown rendering in chat, check `MessageBubble`'s `AssistantBubbleContent` helper and the parser's segment output.
```

- [ ] **Step 2: Add `project_anchor_is_frozen.md`**

Create: `~/.claude/projects/-Users-kochunlong-Library-Mobile-Documents-com-apple-CloudDocs-Nous-archive/memory/project_anchor_is_frozen.md`

```markdown
---
name: Anchor.md is frozen
description: Sources/Nous/Resources/anchor.md is explicitly frozen by AGENTS.md; voice/format/behavior changes go elsewhere
type: project
---

`AGENTS.md:39` and `:131` mark `Sources/Nous/Resources/anchor.md` as frozen — "It is the ground truth against which Nous can measure change over time."

**Why:** Anchor is the system prompt for every LLM call. Changing it silently rewrites the baseline Nous can compare against. Voice/format/behavior changes that look like they belong in anchor go into `ChatViewModel.assembleContext` volatile layer or per-agent `contextAddendum` instead.

**How to apply:** When designing fixes that affect Nous output style or behavior, default to volatile-layer placement. Editing anchor.md requires explicit user approval. Caught 2026-04-26 by codex review of v1 of the chat-markdown-structure spec — spec proposed an anchor edit; codex flagged it as repo-rule violation.
```

- [ ] **Step 3: Update `MEMORY.md` index**

Read: `~/.claude/projects/-Users-kochunlong-Library-Mobile-Documents-com-apple-CloudDocs-Nous-archive/memory/MEMORY.md`

Update the `feedback_no_markdown_bold_in_chat` entry to reflect the new content:

```markdown
- [Chat format policy](feedback_no_markdown_bold_in_chat.md) — markdown structure (headers/bullets/tables) lives in volatile assembleContext layer; emphasis still 「」
```

Add a new entry (anywhere logical):

```markdown
- [Anchor.md is frozen](project_anchor_is_frozen.md) — voice/format/behavior changes go to assembleContext volatile or per-agent addendum, never anchor.md
```

---

## Self-Review

**Spec coverage check** (against spec sections A–F):

- **A. Renderer** — Tasks 1–7 (skeleton, heading, bullet, table, fence, sanitization, view) ✓
- **A. MessageBubble integration with AssistantBubbleContent** — Task 8 ✓
- **B. DirectionAgent** (no change) — covered by spec, no task needed ✓
- **B. BrainstormAgent constraint** — Task 9 ✓
- **B. PlanAgent cap-aware switch + 3 addendums** — Task 10 ✓
- **C. assembleContext format policy** — Task 11 ✓
- **D. (removed in v2)** — n/a ✓
- **E. Validation: unit tests for renderer / sanitization / table strict / fence fallback / Plan addendum / Brainstorm constraint / parser+markdown integration** — Tasks 1–12 ✓
- **E. Validation: manual live tests** — Task 13 (steps 4–9) ✓
- **F. Memory housekeeping** — Task 14 ✓

**Risk coverage check:**

- Performance / Grid table cost — Task 13 step 4 uses a real Plan response with weekly schedule table (multi-row).
- Brainstorm voice regression — Task 13 step 6.
- Sanitization over-stripping — Tasks 6 (preservation tests) cover `int *p`, `*.swift`, `3 * 4`, `snake_case_var`, `__init__`.
- Cap-aware addendum still ignored — Task 13 step 5 tests cap behavior; if regress, escalate to deferred option C per spec.
- Animation value change — Task 13 step 4 verifies under streaming Plan output.
- `<summary>` interaction — Task 12 regression guard.

**Placeholder scan:** No "TBD", "TODO", "implement later". The Task 11 test template explicitly notes "adjust to actual signature" — this is unavoidable since the precise `assembleContext` argument list is internal to the codebase and the implementer must read it. Acceptable.

**Type consistency check:**

- `Segment` enum is defined in Task 1 with cases used identically across Tasks 2–7.
- `ChatMarkdownRenderer.parse(_:)` signature stable from Task 1.
- `ChatMarkdownView(segments:)` signature consistent between Tasks 7 and 8.
- `AssistantBubbleContent(displayText:)` signature consistent between Task 8 and verifications.
- `PlanAgent.maxClarificationTurns` referenced consistently (Task 10 keeps the existing value of 4; tests verify behavior at 4, 5, 6).
- `BrainstormAgent.contextAddendum` returns `String?` consistent with protocol.

No type drift detected.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-26-chat-markdown-structure.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for a 14-task plan with TDD discipline; the per-task review checkpoint catches issues early.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints for review.

Which approach?
