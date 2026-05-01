# Shadow Pattern Multilingual Matching Bugfix Design

## Overview

Shadow Learning already detects some Chinese and Cantonese user signals, but prompt injection can fail for the same language. The detection side uses substring keywords inside `ShadowLearningSignalRecorder`; the injection side uses token overlap inside `ShadowPatternPromptProvider`. For CJK text without ASCII separators, token overlap does not reliably work.

This is a bugfix, not a broad multilingual intelligence feature. The fix is to extract the existing private `ShadowPatternDefinition.keywords` concept into a shared `ShadowPatternLexicon`, then make both detection and injection read aliases from that same source of truth.

## Verified Bug

Current `ShadowPatternPromptProvider.terms(from:)` separates text by `CharacterSet.alphanumerics.inverted`. CJK characters count as alphanumeric letters, so continuous Chinese or Cantonese text becomes one large token.

Example:

```swift
"公仔床唔係扇" -> ["公仔床唔係扇"]
Set(["公仔床唔係扇"]).intersection(Set(["公仔床"])) -> []
```

That means a Chinese or Cantonese phrase can be learned by `ShadowLearningSignalRecorder`, then never become relevant enough to inject back into a prompt. The learning loop is asymmetric:

| Stage | Current mechanism | CJK/Cantonese behavior |
|---|---|---|
| Signal detection | `keywords.contains { text.contains(keyword) }` | Works for exact phrases |
| Prompt injection | token set intersection with `trigger_hint` | Fails for continuous CJK text |

## Goals

- Fix detection-injection asymmetry for the existing six shadow patterns.
- Keep matching deterministic, local, cheap, and inspectable.
- Keep the current SQLite schema unchanged.
- Preserve existing English token overlap behavior.
- Make future alias updates happen in one shared place.

## Non-Goals

- Do not add new pattern kinds such as `invention` or `tradeoff`.
- Do not add `vector_id`, embeddings, or vector search. `shadow_patterns` has no vector or embedding column.
- Do not use an LLM classifier for matching.
- Do not use Levenshtein distance, fuzzy thresholds, or embedding cosine.
- Do not modify `Sources/Nous/Resources/anchor.md`.
- Do not build a user-facing alias editor in this pass.

## Current State

`ShadowLearningSignalRecorder` privately owns the current pattern definitions:

- `first_principles_decision_frame`
- `inversion_before_recommendation`
- `pain_test_for_product_scope`
- `concrete_over_generic`
- `direct_pushback_when_wrong`
- `organize_before_judging`

Each definition includes `keywords`, but those keywords are visible only to signal detection. `ShadowPatternPromptProvider` cannot reuse them, so injection depends on `triggerHint` token overlap.

## Design

### 1. Extract Shared Lexicon

`ShadowPatternLexicon` lives at `Sources/Nous/Services/ShadowPatternLexicon.swift` as a small pure Swift unit. It exposes a stateless static singleton and a designated initializer for tests.

```swift
struct ShadowPatternLexicon {
    static let shared = ShadowPatternLexicon()
    static let aliasMatchBonus: Double = 0.45

    init(aliasesByLabel: [String: [String]] = ShadowPatternLexicon.defaultAliases)

    func aliases(for label: String) -> [String]
    func matchesObservation(label: String, text: String) -> Bool
    func matchingLabels(in text: String) -> [String]
    func aliasMatchBonus(label: String, text: String) -> Double
}
```

Aliases are stored as a flat `[String: [String]]`. The constructor normalizes each entry through `normalized(_:)` and filters through `isAllowedAlias` before storing, so callers can never observe an alias that violates the policy.

The lexicon is the single source of truth for exact phrase aliases across English, Chinese, and Cantonese.

Invariant: `ShadowLearningSignalRecorder` and `ShadowPatternPromptProvider` must read aliases from `ShadowPatternLexicon.shared` (or from a test-injected instance), never from a parallel keyword list. The static-singleton plus designated-init shape exists to enforce this without a protocol.

### 2. Move Existing Keywords Into Lexicon

`ShadowLearningSignalRecorder.ShadowPatternDefinition` should keep only:

- `kind`
- `label`
- `summary`
- `promptFragment`
- `triggerHint`
- `eventNote`

It should not keep a separate `keywords` array. Observation matching becomes:

```swift
lexicon.matchesObservation(label: definition.label, text: normalizedText)
```

This preserves current behavior where possible, while removing the private duplicate source.

### 3. Phrase Alias Policy

Aliases are exact phrase substrings, not fuzzy keywords. The policy is enforced at construction time by `ShadowPatternLexicon.isAllowedAlias`.

Accepted aliases:

- Pure ASCII phrases with at least two whitespace- or punctuation-separated tokens: `pain test`, `worst version`, `push back`, `concrete example`, `organize this`.
- Pure CJK phrases with at least three CJK characters: `第一性原理`, `冇呢样嘢`, `帮我整理`, `先整理` (3 chars, accepted).
- Mixed CJK + ASCII phrases with at least two CJK characters **and** at least one ASCII alphabetic word of four or more letters: `具体 tradeoff`, `具體 tradeoff`. The four-letter floor on the ASCII word filters fillers like `the`, `and`, `but`, `for`, `you`, `use` while admitting content words like `tradeoff`, `push`, `back`, `pain`. The ASCII portion must contain only ASCII letters (a-z, A-Z) — digits, Cyrillic, Greek, and other non-Latin alphabetic characters do **not** satisfy the rule. Examples that are rejected: `具体 2026` (digits), `具体 GPT4` (mixed letters/digits), `具体 русский` (Cyrillic).
- Mixed phrases require whitespace or punctuation between the CJK and ASCII portions, because `isAllowedAlias` splits on `CharacterSet.alphanumerics.inverted`. `具体tradeoff` (no separator) is treated as a single alphanumeric run that contains CJK and is therefore evaluated under the pure-CJK rule, where it has only two CJK chars and is rejected. Always include a space (or punctuation) between CJK and ASCII when authoring mixed aliases.
- Single English carve-out: `inversion`. Violates the multi-word rule but is preserved because the bare word reliably signals the inversion thinking move in Alex's writing.

Rejected aliases (filtered silently by `isAllowedAlias`):

- Single CJK characters.
- Two-character CJK words such as `本质`, `最坏`, `具体`.
- Broad standalone English words such as `generic`, `concrete`, `absence`.
- Mixed phrases with only one CJK character (e.g. `具 a tradeoff`).
- Mixed phrases whose ASCII portion contains no word of four or more letters (e.g. `具体 a`, `具体 it`, `具体 use`).

Known limitations of this policy:

- Single English-word phrases other than `inversion` cannot be added without an additional carve-out. New phrases like `pushback` (one word) would need to be rephrased as `push back` to pass.
- The `inversion` carve-out can produce false positives in software contexts such as `inversion of control` and `matrix inversion`. Tracked as accepted risk; revisit if log review shows misfires.
- The four-letter ASCII floor for mixed phrases is heuristic. Useful three-letter content words like `use` cannot anchor a mixed alias; if such a phrase becomes important in practice, drop the threshold or list both languages separately.

This policy intentionally narrows some prior detection sensitivity. False learning silently changes prompt behavior, so the spec prefers strictness over recall.

### 4. PromptProvider Scoring

Keep the current score components:

```swift
weight * 0.30
+ confidence * 0.20
+ overlapScore
+ modeScore
+ responseBehaviorBonus
```

Replace `overlapScore` with a relevance score that takes the maximum of token overlap and alias match:

```swift
let tokenOverlapScore = min(0.45, Double(inputOverlap) * 0.15)
let aliasMatchBonus = lexicon.aliasMatchBonus(label: pattern.label, text: currentInput)
let relevanceScore = max(tokenOverlapScore, aliasMatchBonus)
```

`aliasMatchBonus(label:text:)` is binary and returns `Double` (not optional):

```swift
0.45 when any alias phrase matches
0.0 otherwise
```

Do not accumulate per-alias bonuses. A sentence with three aliases should not outrank another pattern purely by repetition. Alias matches and token overlap also do not double count; they use `max`.

Final scoring:

```swift
return pattern.weight * 0.30
    + pattern.confidence * 0.20
    + relevanceScore
    + modeScore
    + responseBehaviorBonus
```

The gate remains: if neither token overlap, mode overlap, nor alias match fires, the pattern is not injected.

### 5. Normalization

`ShadowPatternLexicon.normalized(_:)` applies one `String.folding` call followed by whitespace cleanup:

- `caseInsensitive`: lowercase English.
- `widthInsensitive`: collapse full-width forms (e.g. `ＰＡＩＮ ＴＥＳＴ` becomes `pain test`).
- `diacriticInsensitive`: strip combining diacritics. Has no effect on standalone CJK characters but is included for safety on Latin input.
- Collapse runs of whitespace to a single space and trim leading/trailing whitespace and newlines.

Both alias strings (at construction time) and input text (at match time) are passed through `normalized(_:)` before substring matching. CJK punctuation is not stripped.

Simplified versus traditional Chinese is **not** folded automatically; Foundation does not ship a simplified-traditional transformer. The lexicon handles this by listing both forms explicitly when an alias has a meaningful traditional spelling (for example `反过来` and `反過來`, `講到太泛` and `讲到太泛`). Authors adding aliases must include both forms when relevant.

Romanization, pinyin, and jyutping are not used.

### 6. Pattern Alias Set

These are the aliases shipped in `ShadowPatternLexicon.defaultAliases`. They cover the current six labels only and reflect phrases observed in Alex's actual writing rather than a theoretical Cantonese dictionary.

`first_principles_decision_frame`

- `first principle`
- `first principles`
- `first-principles`
- `第一性原理`
- `从根上`
- `由底层逻辑`
- `由底層邏輯`

`inversion_before_recommendation`

- `反过来`
- `反過來`
- `inversion`
- `worst version`
- `最坏版本`
- `最壞版本`

`pain_test_for_product_scope`

- `会痛不痛`
- `会痛唔痛`
- `會痛唔痛`
- `痛不痛`
- `痛唔痛`
- `冇呢样嘢`
- `无呢样嘢`
- `没有这个`
- `pain test`

`concrete_over_generic`

- `讲到太泛`
- `講到太泛`
- `太抽象`
- `具体例子`
- `具體例子`
- `concrete example`
- `具体 tradeoff`
- `具體 tradeoff`

`direct_pushback_when_wrong`

- `push back`
- `直接说`
- `直接講`
- `直接讲`
- `不要顺着我`
- `不要順著我`
- `唔好顺住我`
- `唔好順住我`

`organize_before_judging`

- `我说不清`
- `我講唔清`
- `我讲唔清`
- `我讲到好乱`
- `我講到好亂`
- `帮我整理`
- `幫我整理`
- `先整理`
- `organize this`

When adding an alias, include both simplified and traditional forms if both could appear in writing. The lexicon constructor silently filters any entry that fails `isAllowedAlias`, so authors must verify additions land by reading them back via `lexicon.aliases(for:)` or by writing a test.

## Data Flow

```text
User message
  -> ShadowLearningSignalRecorder
  -> ShadowPatternLexicon.matchesObservation(label:text:)
  -> ShadowLearningStore upserts / reinforces pattern

Later turn
  -> TurnPlanner
  -> ShadowPatternPromptProvider
  -> fetch prompt-eligible shadow patterns
  -> ShadowPatternLexicon.aliasMatchScore(label:text:)
  -> score and select at most three hints
  -> PromptContextAssembler injects volatile SHADOW THINKING HINTS
```

## Testing Plan

Tests live in `Tests/NousTests/ShadowPatternLexiconTests.swift` plus the existing recorder and provider suites. Phrases below match the actual fixtures shipped with the implementation.

### Lexicon Tests (`ShadowPatternLexiconTests`)

- `冇呢样嘢，会痛唔痛？` matches `pain_test_for_product_scope`.
- `先谂下最坏版本会系点` matches `inversion_before_recommendation`.
- `唔好讲到太泛，畀个具体例子` matches `concrete_over_generic`.
- `如果我错，直接说，唔好顺住我` matches `direct_pushback_when_wrong`.
- `我讲到好乱，帮我整理先` matches `organize_before_judging`.
- `用第一性原理重新睇一次` matches `first_principles_decision_frame`.
- `今日食咩好？` matches no pattern (`matchingLabels` returns empty).
- Single CJK words such as `具体`, `本质`, `最坏` and standalone `absence` do not match their respective labels.
- A custom-instantiated lexicon silently drops `具体`, `本质`, `absence` while keeping `具体例子`, `pain test`, and `inversion`.
- `aliasMatchBonus` returns exactly `0.45` on any match and stays at `0.45` even when multiple aliases co-occur in the same input (binary, not additive).
- `PAIN　TEST 呢关过唔到` (full-width space) matches `pain_test_for_product_scope`. `请你 PUSH BACK` matches `direct_pushback_when_wrong`.
- `唔好讲到太泛，畀啲具体 tradeoff 我睇` matches `concrete_over_generic` via the mixed-language alias.
- A custom-instantiated lexicon drops `具体 a`, `具体 it`, `具体 use`, and `具 a tradeoff` while keeping `具体 tradeoff`.
- A custom-instantiated lexicon drops `具体 2026`, `具体 GPT4`, and `具体 русский` because the ASCII portion must consist of ASCII letters only.
- `这是具体方案，但 tradeoff 之后再讲` does **not** match `concrete_over_generic`. The mixed alias `具体 tradeoff` requires a contiguous substring; non-contiguous occurrences of `具体` and `tradeoff` separated by other text do not trigger.

### Signal Recorder Tests (`ShadowLearningSignalRecorderTests`)

- Existing English and Chinese observation tests continue to pass after the keyword field is removed.
- A Cantonese pain-test message (`呢个 feature 冇呢样嘢，会痛唔痛？`) records `pain_test_for_product_scope`.
- A Cantonese direct-pushback message records `direct_pushback_when_wrong`.
- Replaying the same message does not duplicate events; lifecycle reinforcement still fires.
- Negation handling in `isCorrection` continues to work for `first_principles_decision_frame`. The negation keyword list (`别用`, `不要`, `not use`, `don't use`) remains hardcoded in `ShadowLearningSignalRecorder` and is intentionally **not** unified into the lexicon in this pass.

### Prompt Provider Tests (`ShadowPatternPromptProviderTests`)

- Cantonese input (`呢个 feature 冇呢样嘢，会痛唔痛？`) injects the matching prompt hint even when English token overlap with `triggerHint` is empty.
- English input that matches both alias and token overlap does not double count; the score uses `max(tokenOverlapScore, aliasMatchBonus)`.
- Multiple aliases in one input still produce only one `0.45` bonus.
- Unrelated Cantonese input does not inject any hint.
- The provider still returns at most three prompt fragments.

## Acceptance Criteria

- `ShadowLearningSignalRecorder` and `ShadowPatternPromptProvider` both use `ShadowPatternLexicon`.
- There is no remaining private keyword list in `ShadowLearningSignalRecorder`.
- No SQLite schema changes are made.
- No vector, embedding, fuzzy, or LLM matching is introduced.
- Existing shadow learning lifecycle behavior remains unchanged.
- All new tests and existing shadow learning tests pass:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' \
  -only-testing:NousTests/ShadowLearningSignalRecorderTests \
  -only-testing:NousTests/ShadowPatternPromptProviderTests \
  -only-testing:NousTests/TurnPlannerShadowLearningTests \
  -only-testing:NousTests/PromptContextAssemblerShadowLearningTests
```

## Risks

The main risk is false positives from broad aliases. The phrase policy deliberately rejects short generic aliases to reduce that risk. The `inversion` single-word carve-out is the most exposed case — software discussions involving `inversion of control` or `matrix inversion` will misfire. Accepted for v1; revisit if log review shows misfires.

The second risk is missed detections from being stricter than the old keyword list. That is acceptable for v1 because missed weak learning is recoverable, while wrong learning silently changes prompt behavior. Mixed-language phrases like `具体 tradeoff` are now accepted via the cjk≥2 + ASCII-word≥4 rule; `直接 push back` already matched the existing `push back` ASCII alias and does not need a mixed entry. The remaining gap is mixed phrases whose ASCII portion is short (e.g. `具体 use case` matches because `case` is four letters, but `具体 use` alone does not).

The third risk is future drift if another developer adds aliases in one caller only. The shared lexicon invariant and tests should catch that.

The fourth risk is negation drift. Negation keywords (`别用`, `不要`, `not use`, `don't use`) live inside `ShadowLearningSignalRecorder.isCorrection`, not the lexicon. Adding multilingual negation forms (e.g. `唔好用`, `冇必要`) will silently bypass the lexicon's policy filter and is invisible to `ShadowPatternPromptProvider`. Unifying negation into the lexicon is deferred future work; keep the current footprint small until there is evidence it matters.

The fifth risk is silent alias drops. `ShadowPatternLexicon.init` filters out any entry that fails `isAllowedAlias` without warning. An author who adds a two-CJK-character or single English-word alias will find it absent at runtime with no error. Mitigation: write a focused test for any newly added alias.

## Implementation Notes

Use small, pure helpers. Do not introduce a protocol unless tests need injection. The lexicon should be easy to inspect in one file and should not depend on SQLite, LLM services, or `TurnPlanner`.

The first implementation should be a refactor plus caller wiring:

1. Add `ShadowPatternLexicon`.
2. Move aliases out of `ShadowLearningSignalRecorder`.
3. Inject or instantiate the lexicon in `ShadowLearningSignalRecorder`.
4. Use the same lexicon in `ShadowPatternPromptProvider`.
5. Add tests for CJK/Cantonese injection and false positives.

That is the whole scope.
