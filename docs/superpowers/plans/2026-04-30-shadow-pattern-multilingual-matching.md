# Shadow Pattern Multilingual Matching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the existing shadow learning asymmetry where Chinese/Cantonese feedback can be detected and stored, but later cannot be matched for prompt injection.

**Architecture:** Extract the existing private `ShadowLearningSignalRecorder` keyword knowledge into a shared `ShadowPatternLexicon`, then make both detection and prompt injection read aliases from that same source of truth. PromptProvider keeps English token overlap, adds exact phrase alias matching, and scores alias relevance with `max(tokenOverlapScore, aliasMatchBonus)`.

**Tech Stack:** Swift, XCTest, existing raw SQLite test doubles, no new dependencies, no database migration.

---

## Constraints

- Do not modify `Sources/Nous/Resources/anchor.md`.
- Do not add third-party dependencies.
- Do not add DB columns, vector IDs, embeddings, cosine matching, Levenshtein distance, fuzzy thresholds, or LLM classification.
- Do not add new pattern labels. The implementation keeps the current six labels:
  - `first_principles_decision_frame`
  - `inversion_before_recommendation`
  - `pain_test_for_product_scope`
  - `concrete_over_generic`
  - `direct_pushback_when_wrong`
  - `organize_before_judging`
- Keep existing public initializers source-compatible by adding defaulted `lexicon:` parameters.
- Treat broad one-word aliases as invalid for substring matching. In particular, do not keep standalone aliases such as `generic`, `concrete`, `absence`, `底层`, `本质`, `最坏`, or `具体`.
- Alias hits are exact phrase or substring hits after normalization. They are not semantic similarity.
- Alias relevance is binary. One alias hit and three alias hits both contribute `0.45`.
- If English token overlap and alias matching both fire, PromptProvider uses the larger contribution, not the sum.

## Current Failure

`ShadowPatternPromptProvider.terms(from:)` tokenizes by non-alphanumeric boundaries. A CJK sentence with no ASCII separator is one token, so this input:

```swift
"公仔床唔係扇"
```

produces one term:

```swift
["公仔床唔係扇"]
```

That term does not intersect with a learned trigger hint such as `"公仔床"`. As a result, Chinese/Cantonese patterns can be learned by `ShadowLearningSignalRecorder`, but cannot be injected later by `ShadowPatternPromptProvider`.

## Files To Change

- `Sources/Nous/Services/ShadowPatternLexicon.swift` — new shared alias source of truth.
- `Sources/Nous/Services/ShadowLearningSignalRecorder.swift` — remove private keyword ownership and use `ShadowPatternLexicon`.
- `Sources/Nous/Services/ShadowPatternPromptProvider.swift` — add lexicon alias matching and scoring.
- `Tests/NousTests/ShadowPatternLexiconTests.swift` — new focused lexicon tests.
- `Tests/NousTests/ShadowLearningSignalRecorderTests.swift` — add regression tests for multilingual detection through shared lexicon.
- `Tests/NousTests/ShadowPatternPromptProviderTests.swift` — add regression tests for Cantonese injection and non-additive scoring.

## Task 1: Add Shared Lexicon With Tests

- [ ] Add `Tests/NousTests/ShadowPatternLexiconTests.swift`.
- [ ] Add `Sources/Nous/Services/ShadowPatternLexicon.swift`.
- [ ] Regenerate the Xcode project so the new source and test files are included:

```bash
xcodegen generate
```

- [ ] Run the lexicon tests and confirm they pass:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ShadowPatternLexiconTests
```

Expected result:

```text
** TEST SUCCEEDED **
```

- [ ] Commit:

```bash
git add Sources/Nous/Services/ShadowPatternLexicon.swift Tests/NousTests/ShadowPatternLexiconTests.swift Nous.xcodeproj/project.pbxproj
git commit -m "Add shared shadow pattern lexicon"
```

### Test File

Create `Tests/NousTests/ShadowPatternLexiconTests.swift`:

```swift
import XCTest
@testable import Nous

final class ShadowPatternLexiconTests: XCTestCase {
    func testMatchesCantoneseAndChineseAliasesToCurrentLabels() {
        let lexicon = ShadowPatternLexicon.shared

        XCTAssertTrue(lexicon.matchesObservation(label: "pain_test_for_product_scope", text: "冇呢样嘢，会痛唔痛？"))
        XCTAssertTrue(lexicon.matchesObservation(label: "inversion_before_recommendation", text: "先谂下最坏版本会系点"))
        XCTAssertTrue(lexicon.matchesObservation(label: "concrete_over_generic", text: "唔好讲到太泛，畀个具体例子"))
        XCTAssertTrue(lexicon.matchesObservation(label: "direct_pushback_when_wrong", text: "如果我错，直接说，唔好顺住我"))
        XCTAssertTrue(lexicon.matchesObservation(label: "organize_before_judging", text: "我讲到好乱，帮我整理先"))
        XCTAssertTrue(lexicon.matchesObservation(label: "first_principles_decision_frame", text: "用第一性原理重新睇一次"))
    }

    func testUnrelatedCantoneseDoesNotMatchAnyPattern() {
        let matches = ShadowPatternLexicon.shared.matchingLabels(in: "今日食咩好？")

        XCTAssertTrue(matches.isEmpty)
    }

    func testShortGenericAliasesAreNotAcceptedAsStandaloneMatches() {
        let lexicon = ShadowPatternLexicon.shared

        XCTAssertFalse(lexicon.matchesObservation(label: "concrete_over_generic", text: "具体"))
        XCTAssertFalse(lexicon.matchesObservation(label: "first_principles_decision_frame", text: "本质"))
        XCTAssertFalse(lexicon.matchesObservation(label: "inversion_before_recommendation", text: "最坏"))
        XCTAssertFalse(lexicon.matchesObservation(label: "pain_test_for_product_scope", text: "absence"))
    }

    func testInitializerFiltersShortGenericAliases() {
        let lexicon = ShadowPatternLexicon(aliasesByLabel: [
            "custom": ["具体", "本质", "absence", "具体例子", "pain test", "inversion"]
        ])

        XCTAssertFalse(lexicon.matchesObservation(label: "custom", text: "具体"))
        XCTAssertFalse(lexicon.matchesObservation(label: "custom", text: "本质"))
        XCTAssertFalse(lexicon.matchesObservation(label: "custom", text: "absence"))
        XCTAssertTrue(lexicon.matchesObservation(label: "custom", text: "具体例子"))
        XCTAssertTrue(lexicon.matchesObservation(label: "custom", text: "pain test"))
        XCTAssertTrue(lexicon.matchesObservation(label: "custom", text: "inversion"))
    }

    func testAliasMatchBonusIsBinary() {
        let lexicon = ShadowPatternLexicon.shared

        XCTAssertEqual(
            lexicon.aliasMatchBonus(label: "pain_test_for_product_scope", text: "会痛唔痛？"),
            0.45,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            lexicon.aliasMatchBonus(label: "pain_test_for_product_scope", text: "冇呢样嘢，会痛唔痛？pain test"),
            0.45,
            accuracy: 0.0001
        )
    }

    func testNormalizationHandlesCaseAndFullWidthSpaces() {
        let lexicon = ShadowPatternLexicon.shared

        XCTAssertTrue(lexicon.matchesObservation(label: "pain_test_for_product_scope", text: "PAIN　TEST 呢关过唔到"))
        XCTAssertTrue(lexicon.matchesObservation(label: "direct_pushback_when_wrong", text: "请你 PUSH BACK"))
    }
}
```

### Implementation

Create `Sources/Nous/Services/ShadowPatternLexicon.swift`:

```swift
import Foundation

struct ShadowPatternLexicon {
    static let shared = ShadowPatternLexicon()

    static let aliasMatchBonus = 0.45

    private let aliasesByLabel: [String: [String]]

    init(aliasesByLabel: [String: [String]] = ShadowPatternLexicon.defaultAliases) {
        self.aliasesByLabel = aliasesByLabel.mapValues { aliases in
            aliases
                .map(Self.normalized)
                .filter(Self.isAllowedAlias)
                .filter { !$0.isEmpty }
        }
    }

    func aliases(for label: String) -> [String] {
        aliasesByLabel[label] ?? []
    }

    func matchesObservation(label: String, text: String) -> Bool {
        containsAlias(label: label, text: text)
    }

    func matchingLabels(in text: String) -> [String] {
        aliasesByLabel.keys
            .filter { containsAlias(label: $0, text: text) }
            .sorted()
    }

    func aliasMatchBonus(label: String, text: String) -> Double {
        containsAlias(label: label, text: text) ? Self.aliasMatchBonus : 0.0
    }

    private func containsAlias(label: String, text: String) -> Bool {
        let normalizedText = Self.normalized(text)
        return aliases(for: label).contains { alias in
            normalizedText.contains(alias)
        }
    }

    static func normalized(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAllowedAlias(_ alias: String) -> Bool {
        let cjkCount = alias.unicodeScalars.filter(Self.isCJK).count
        if cjkCount > 0 {
            return cjkCount >= 3
        }

        let wordCount = alias
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .count
        return wordCount >= 2 || alias == "inversion"
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    private static let defaultAliases: [String: [String]] = [
        "first_principles_decision_frame": [
            "first principle",
            "first principles",
            "first-principles",
            "第一性原理",
            "从根上",
            "由底层逻辑",
            "由底層邏輯"
        ],
        "inversion_before_recommendation": [
            "反过来",
            "反過來",
            "inversion",
            "worst version",
            "最坏版本",
            "最壞版本"
        ],
        "pain_test_for_product_scope": [
            "会痛不痛",
            "会痛唔痛",
            "會痛唔痛",
            "痛不痛",
            "痛唔痛",
            "冇呢样嘢",
            "无呢样嘢",
            "没有这个",
            "pain test"
        ],
        "concrete_over_generic": [
            "讲到太泛",
            "講到太泛",
            "太抽象",
            "具体例子",
            "具體例子",
            "concrete example"
        ],
        "direct_pushback_when_wrong": [
            "push back",
            "直接说",
            "直接講",
            "直接讲",
            "不要顺着我",
            "不要順著我",
            "唔好顺住我",
            "唔好順住我"
        ],
        "organize_before_judging": [
            "我说不清",
            "我講唔清",
            "我讲唔清",
            "我讲到好乱",
            "我講到好亂",
            "帮我整理",
            "幫我整理",
            "先整理",
            "organize this"
        ]
    ]
}
```

### Notes

- The alias table intentionally removes the old standalone short aliases `底层`, `本质`, `最坏`, `具体`, `generic`, `concrete`, and `absence`.
- `inversion` remains because it is a domain-specific English term rather than a broad adjective.
- `pain test`, `push back`, and `first principles` remain because they are multi-word English phrases.

## Task 2: Refactor Signal Recorder To Use Shared Lexicon

- [ ] Inject `ShadowPatternLexicon` into `ShadowLearningSignalRecorder`.
- [ ] Remove `keywords` from the private `ShadowPatternDefinition`.
- [ ] Replace `definition.matches(text)` with `lexicon.matchesObservation(label:text:)`.
- [ ] Update first-principles correction naming to read the pattern name from `ShadowPatternLexicon`; keep negation words local to correction handling.
- [ ] Add regression tests proving Chinese/Cantonese detection still records patterns through the shared lexicon.
- [ ] Update existing recorder tests that currently depend on removed short aliases.
- [ ] Run `ShadowLearningSignalRecorderTests`:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ShadowLearningSignalRecorderTests
```

Expected result:

```text
** TEST SUCCEEDED **
```

- [ ] Commit:

```bash
git add Sources/Nous/Services/ShadowLearningSignalRecorder.swift Tests/NousTests/ShadowLearningSignalRecorderTests.swift
git commit -m "Use shared lexicon for shadow learning detection"
```

### Implementation Edits

In `Sources/Nous/Services/ShadowLearningSignalRecorder.swift`, change the initializer shape without breaking existing call sites:

```swift
final class ShadowLearningSignalRecorder {
    private let store: any ShadowLearningStoring
    private let lexicon: ShadowPatternLexicon

    init(store: any ShadowLearningStoring, lexicon: ShadowPatternLexicon = .shared) {
        self.store = store
        self.lexicon = lexicon
    }
```

In `recordSignals`, replace the keyword loop while keeping the existing `maxSignals` and `recordObservation` behavior:

```swift
for definition in Self.definitions where lexicon.matchesObservation(label: definition.label, text: text) {
    if let maxSignals, recordedCount >= maxSignals {
        break
    }
    let didRecord = try recordObservation(definition, message: message, userId: userId, now: now)
    if didRecord {
        recordedCount += 1
    }
}
```

Remove `keywords` and `matches` from `ShadowPatternDefinition`:

```swift
private struct ShadowPatternDefinition {
    let kind: ShadowPatternKind
    let label: String
    let summary: String
    let triggerHint: String
    let promptFragment: String
    let eventNote: String
}
```

Update each entry in `Self.definitions` so it contains only `kind`, `label`, `summary`, `triggerHint`, `promptFragment`, and `eventNote`.

Update `isCorrection(_:for:)` so the pattern-name side comes from the shared lexicon:

```swift
private func isCorrection(_ text: String, for label: String) -> Bool {
    switch label {
    case "first_principles_decision_frame":
        let negates = text.contains("别用")
            || text.contains("不要")
            || text.contains("not use")
            || text.contains("don't use")
        let namesPattern = lexicon.matchesObservation(label: label, text: text)
        return negates && namesPattern
    default:
        return false
    }
}
```

### Test Additions

Add these tests to `Tests/NousTests/ShadowLearningSignalRecorderTests.swift`:

```swift
func testRecordsCantonesePainTestThroughSharedLexicon() throws {
    let nodeStore = try NodeStore(path: ":memory:")
    let store = ShadowLearningStore(nodeStore: nodeStore)
    let recorder = ShadowLearningSignalRecorder(store: store)
    let message = userMessage(
        id: "00000000-0000-0000-0000-000000003014",
        content: "呢个 feature 冇呢样嘢，会痛唔痛？",
        timestamp: 1_300
    )
    try persist([message], in: nodeStore)

    try recorder.recordSignals(from: message, userId: "alex")

    let patterns = try store.fetchPatterns(userId: "alex")
    XCTAssertEqual(patterns.map(\.label), ["pain_test_for_product_scope"])
}

func testRecordsChinesePushbackThroughSharedLexicon() throws {
    let nodeStore = try NodeStore(path: ":memory:")
    let store = ShadowLearningStore(nodeStore: nodeStore)
    let recorder = ShadowLearningSignalRecorder(store: store)
    let message = userMessage(
        id: "00000000-0000-0000-0000-000000003015",
        content: "如果我错，直接说，不要顺着我。",
        timestamp: 1_400
    )
    try persist([message], in: nodeStore)

    try recorder.recordSignals(from: message, userId: "alex")

    let patterns = try store.fetchPatterns(userId: "alex")
    XCTAssertEqual(patterns.map(\.label), ["direct_pushback_when_wrong"])
}

func testDoesNotRecordStandaloneGenericShortAlias() throws {
    let nodeStore = try NodeStore(path: ":memory:")
    let store = ShadowLearningStore(nodeStore: nodeStore)
    let recorder = ShadowLearningSignalRecorder(store: store)
    let message = userMessage(
        id: "00000000-0000-0000-0000-000000003016",
        content: "具体",
        timestamp: 1_500
    )
    try persist([message], in: nodeStore)

    try recorder.recordSignals(from: message, userId: "alex")

    XCTAssertTrue(try store.fetchPatterns(userId: "alex").isEmpty)
}
```

Update existing tests in `Tests/NousTests/ShadowLearningSignalRecorderTests.swift` that currently depend on short aliases intentionally removed by this fix:

```swift
// In testRepeatedObservationReinforcesExistingPattern:
let first = userMessage(
    id: "00000000-0000-0000-0000-000000003011",
    content: "这个决定先用第一性原理",
    timestamp: 1_000
)
let second = userMessage(
    id: "00000000-0000-0000-0000-000000003012",
    content: "再从根上拆一下",
    timestamp: 1_100
)

// In testReplayingSameMessageDoesNotReinforceOrDuplicateEvents:
let message = userMessage(
    id: "00000000-0000-0000-0000-000000003013",
    content: "这个判断先从根上拆",
    timestamp: 1_200
)
```

## Task 3: Add Alias Matching To PromptProvider Scoring

- [ ] Inject `ShadowPatternLexicon` into `ShadowPatternPromptProvider`.
- [ ] Keep token overlap for English inputs.
- [ ] Add alias matching as a binary `0.45` relevance signal.
- [ ] Gate prompt eligibility on `inputOverlap > 0 || modeOverlap > 0 || aliasMatchBonus > 0`.
- [ ] Compute final relevance as `max(tokenOverlapScore, aliasMatchBonus)`.
- [ ] Do not add alias bonus to token overlap.
- [ ] Do not add one bonus per alias.
- [ ] Add tests for Cantonese injection, English dedupe, binary alias scoring, and unrelated Cantonese no-match.
- [ ] Run `ShadowPatternPromptProviderTests`:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ShadowPatternPromptProviderTests
```

Expected result:

```text
** TEST SUCCEEDED **
```

- [ ] Commit:

```bash
git add Sources/Nous/Services/ShadowPatternPromptProvider.swift Tests/NousTests/ShadowPatternPromptProviderTests.swift
git commit -m "Match shadow prompts with multilingual aliases"
```

### Implementation Edits

In `Sources/Nous/Services/ShadowPatternPromptProvider.swift`, change the initializer shape without breaking existing call sites:

```swift
final class ShadowPatternPromptProvider: ShadowPatternPromptProviding {
    private let store: any ShadowLearningStoring
    private let lexicon: ShadowPatternLexicon

    init(store: any ShadowLearningStoring, lexicon: ShadowPatternLexicon = .shared) {
        self.store = store
        self.lexicon = lexicon
    }
```

Change the scoring call in `promptHints` and keep the existing sort/limit behavior:

```swift
return patterns
    .compactMap { pattern -> (pattern: ShadowLearningPattern, score: Double)? in
        guard let score = score(
            pattern,
            currentInput: currentInput,
            inputTerms: inputTerms,
            modeTerms: modeTerms
        ) else {
            return nil
        }
        return (pattern, score)
    }
    .sorted {
        if $0.score == $1.score {
            return $0.pattern.label < $1.pattern.label
        }
        return $0.score > $1.score
    }
    .prefix(3)
    .map(\.pattern.promptFragment)
```

Replace the private `score` implementation with:

```swift
private func score(
    _ pattern: ShadowLearningPattern,
    currentInput: String,
    inputTerms: Set<String>,
    modeTerms: Set<String>
) -> Double? {
    let triggerTerms = terms(from: pattern.triggerHint)
    let inputOverlap = triggerTerms.intersection(inputTerms).count
    let modeOverlap = triggerTerms.intersection(modeTerms).count
    let aliasMatchBonus = lexicon.aliasMatchBonus(label: pattern.label, text: currentInput)

    guard inputOverlap > 0 || modeOverlap > 0 || aliasMatchBonus > 0 else {
        return nil
    }

    let tokenOverlapScore = min(0.45, Double(inputOverlap) * 0.15)
    let relevanceScore = max(tokenOverlapScore, aliasMatchBonus)
    let modeScore = min(0.10, Double(modeOverlap) * 0.05)
    let responseBehaviorBonus = pattern.kind == .responseBehavior ? 0.08 : 0.0

    return pattern.weight * 0.30
        + pattern.confidence * 0.20
        + relevanceScore
        + modeScore
        + responseBehaviorBonus
}
```

Leave `terms(from:)` in place. It remains useful for English token overlap and mode matching.

### Test Additions

Add these tests to `Tests/NousTests/ShadowPatternPromptProviderTests.swift`. Use the existing `pattern(label:kind:trigger:fragment:weight:now:)` helper in that file.

Cantonese prompt injection when token overlap would fail:

```swift
func testCantoneseAliasInjectsPatternWhenTokenOverlapWouldFail() throws {
    let nodeStore = try NodeStore(path: ":memory:")
    let store = ShadowLearningStore(nodeStore: nodeStore)
    let now = Date(timeIntervalSince1970: 10_100)
    try store.upsertPattern(pattern(
        label: "pain_test_for_product_scope",
        kind: .thinkingMove,
        trigger: "product scope pain test",
        fragment: "Ask whether the absence would hurt.",
        weight: 0.80,
        now: now
    ))
    let provider = ShadowPatternPromptProvider(store: store)

    let hints = try provider.promptHints(
        userId: "alex",
        currentInput: "呢个 feature 冇呢样嘢，会痛唔痛？",
        activeQuickActionMode: nil,
        now: now
    )

    XCTAssertEqual(hints, ["Ask whether the absence would hurt."])
}
```

Unrelated Cantonese does not inject:

```swift
func testUnrelatedCantoneseDoesNotInjectPattern() throws {
    let nodeStore = try NodeStore(path: ":memory:")
    let store = ShadowLearningStore(nodeStore: nodeStore)
    let now = Date(timeIntervalSince1970: 10_200)
    try store.upsertPattern(pattern(
        label: "pain_test_for_product_scope",
        kind: .thinkingMove,
        trigger: "product scope pain test",
        fragment: "Ask whether the absence would hurt.",
        weight: 0.80,
        now: now
    ))
    let provider = ShadowPatternPromptProvider(store: store)

    let hints = try provider.promptHints(
        userId: "alex",
        currentInput: "今日食咩好？",
        activeQuickActionMode: nil,
        now: now
    )

    XCTAssertTrue(hints.isEmpty)
}
```

English token overlap and alias matching use `max`, not sum. This test is designed so the competitor wins only if the pain pattern uses `max(tokenOverlapScore, aliasMatchBonus)`.

```swift
func testEnglishAliasAndTokenOverlapDoNotDoubleCount() throws {
    let nodeStore = try NodeStore(path: ":memory:")
    let store = ShadowLearningStore(nodeStore: nodeStore)
    let now = Date(timeIntervalSince1970: 10_300)
    try store.upsertPattern(pattern(
        label: "pain_test_for_product_scope",
        kind: .thinkingMove,
        trigger: "pain test product scope",
        fragment: "Pain test fragment.",
        weight: 0.25,
        now: now
    ))
    try store.upsertPattern(pattern(
        label: "concrete_over_generic",
        kind: .responseBehavior,
        trigger: "product",
        fragment: "Competitor fragment.",
        weight: 1.00,
        now: now
    ))
    let provider = ShadowPatternPromptProvider(store: store)

    let hints = try provider.promptHints(
        userId: "alex",
        currentInput: "pain test product scope",
        activeQuickActionMode: nil,
        now: now
    )

    XCTAssertEqual(hints.first, "Competitor fragment.")
}
```

Multiple alias hits are binary, not cumulative. This test is designed so the competitor wins if the pain pattern receives one `0.45` bonus, and loses if each matched alias adds another `0.45`.

```swift
func testMultipleAliasHitsDoNotAccumulate() throws {
    let nodeStore = try NodeStore(path: ":memory:")
    let store = ShadowLearningStore(nodeStore: nodeStore)
    let now = Date(timeIntervalSince1970: 10_400)
    try store.upsertPattern(pattern(
        label: "pain_test_for_product_scope",
        kind: .thinkingMove,
        trigger: "scope",
        fragment: "Pain test fragment.",
        weight: 0.25,
        now: now
    ))
    try store.upsertPattern(pattern(
        label: "concrete_over_generic",
        kind: .responseBehavior,
        trigger: "feature",
        fragment: "Competitor fragment.",
        weight: 1.00,
        now: now
    ))
    let provider = ShadowPatternPromptProvider(store: store)

    let hints = try provider.promptHints(
        userId: "alex",
        currentInput: "呢个 feature 冇呢样嘢，会痛唔痛？",
        activeQuickActionMode: nil,
        now: now
    )

    XCTAssertEqual(hints.first, "Competitor fragment.")
}
```

## Task 4: Verify Cross-Flow Behavior

- [ ] Run focused tests that cover learning, prompt assembly, turn planning, and chat integration:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ShadowPatternLexiconTests -only-testing:NousTests/ShadowLearningSignalRecorderTests -only-testing:NousTests/ShadowPatternPromptProviderTests -only-testing:NousTests/TurnPlannerShadowLearningTests -only-testing:NousTests/PromptContextAssemblerShadowLearningTests -only-testing:NousTests/ChatTurnRunnerShadowLearningTests
```

Expected result:

```text
** TEST SUCCEEDED **
```

- [ ] If this command fails because of the local macOS SDK or simulator environment, capture the exact failing command and the first actionable compiler or test error in the final report.
- [ ] Commit any required fixes:

```bash
git add Sources/Nous/Services/ShadowPatternLexicon.swift Sources/Nous/Services/ShadowLearningSignalRecorder.swift Sources/Nous/Services/ShadowPatternPromptProvider.swift Tests/NousTests/ShadowPatternLexiconTests.swift Tests/NousTests/ShadowLearningSignalRecorderTests.swift Tests/NousTests/ShadowPatternPromptProviderTests.swift
git commit -m "Verify multilingual shadow pattern matching"
```

Skip this commit if Task 4 produces no file changes.

## Task 5: Final Full-Suite Verification

- [ ] Run diff hygiene:

```bash
git diff --check
```

Expected output: no output and exit code 0.

- [ ] Run the full test suite:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'
```

Expected result:

```text
** TEST SUCCEEDED **
```

- [ ] Inspect the final diff:

```bash
git diff origin/main...
```

- [ ] Confirm the diff contains only the multilingual shadow pattern matching work plus the already-existing dirty files that were present before this plan.
- [ ] Final report must include:
  - files changed by this implementation,
  - focused test command result,
  - full suite result,
  - whether unrelated pre-existing dirty files remain untouched.

## Review Checklist

- [ ] Detection and injection both read aliases from `ShadowPatternLexicon`.
- [ ] There is no second keyword list in `ShadowLearningSignalRecorder`.
- [ ] `ShadowPatternPromptProvider` still supports English token overlap.
- [ ] Chinese/Cantonese phrase matching works without token overlap.
- [ ] `今日食咩好？` does not inject a shadow prompt.
- [ ] `具体`, `本质`, `最坏`, and `absence` do not match as standalone aliases.
- [ ] Alias score is exactly `0.45`.
- [ ] Multiple aliases do not accumulate.
- [ ] Alias and token overlap use `max`, not sum.
- [ ] No schema migration exists.
- [ ] No vector ID, embedding, cosine, Levenshtein, fuzzy threshold, or LLM classifier was added.
