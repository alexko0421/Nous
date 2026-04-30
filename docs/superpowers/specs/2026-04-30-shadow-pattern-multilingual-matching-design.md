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

Create `ShadowPatternLexicon` as a small pure Swift unit in `Sources/Nous/Services/ShadowPatternLexicon.swift`.

It owns aliases by shadow pattern label:

```swift
struct ShadowPatternLexicon {
    func aliases(for label: String) -> ShadowPatternAliases
    func matchesObservation(label: String, text: String) -> Bool
    func aliasMatchScore(label: String, text: String) -> Double?
}

struct ShadowPatternAliases {
    let phrases: [String]
}
```

The lexicon is the single source of truth for exact phrase aliases across English, Chinese, and Cantonese.

Invariant: `ShadowLearningSignalRecorder` and `ShadowPatternPromptProvider` must read aliases from the same `ShadowPatternLexicon` instance, or from the same stateless singleton if the implementation keeps the lexicon static. They cannot each maintain their own keyword list.

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

Aliases are exact phrase substrings, not fuzzy keywords.

Accepted aliases:

- Multi-word English phrases: `pain test`, `worst version`, `push back`
- Chinese/Cantonese phrases with at least three CJK characters: `第一性原理`, `冇呢样嘢`, `会唔会痛`, `唔好咁泛`, `帮我整理`
- Mixed language phrases that Alex actually writes: `具体 tradeoff`, `直接 push back`

Rejected aliases:

- Single CJK characters
- Two-character generic words such as `本质`, `最坏`, `具体`
- Broad standalone English words such as `generic`, `concrete`, `absence`

This intentionally narrows some existing detection sensitivity. The tradeoff is acceptable because short generic aliases create false positives, and false learning is worse than missed weak learning. The system can still learn from clearer repeated phrases.

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
let aliasMatchBonus = lexicon.aliasMatchScore(label: pattern.label, text: currentInput) ?? 0
let relevanceScore = max(tokenOverlapScore, aliasMatchBonus)
```

`aliasMatchBonus` is binary:

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

Use lightweight normalization only:

- Lowercase English.
- Trim whitespace and newlines.
- Normalize full-width spaces to normal spaces.
- Do not strip Chinese or Cantonese punctuation globally unless tests prove it is needed.
- Do not transliterate or romanize.

Exact substring matching should operate on normalized strings.

### 6. Pattern Alias Set

Initial aliases cover the current six labels only.

`first_principles_decision_frame`

- `first principles`
- `first-principles`
- `第一性原理`
- `从根上`
- `由底层`
- `底层逻辑`

`inversion_before_recommendation`

- `inversion`
- `worst version`
- `反过来睇`
- `反过来看`
- `最坏版本`
- `最坏情况`

`pain_test_for_product_scope`

- `pain test`
- `会不会痛`
- `会唔会痛`
- `痛不痛`
- `痛唔痛`
- `冇呢样嘢`
- `没有这个会`

`concrete_over_generic`

- `too generic`
- `唔好咁泛`
- `不要太泛`
- `讲具体`
- `讲返具体`
- `具体 tradeoff`

`direct_pushback_when_wrong`

- `push back`
- `直接说`
- `直接讲`
- `不要顺着我`
- `唔好顺住我`
- `直接反驳`

`organize_before_judging`

- `帮我整理`
- `帮我梳理`
- `整理下先`
- `梳理下先`
- `我说不清`
- `我講唔清`
- `organize my thoughts`

If an alias violates the phrase policy during implementation, prefer dropping it over weakening the policy.

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

Add focused tests around the shared lexicon and provider behavior.

### Lexicon Tests

- `冇呢样嘢会唔会痛` matches `pain_test_for_product_scope`.
- `反过来睇最坏版本` matches `inversion_before_recommendation`.
- `唔好咁泛，讲具体 tradeoff` matches `concrete_over_generic`.
- `直接 push back，唔好顺住我` matches `direct_pushback_when_wrong`.
- `帮我整理下先，之后再判断` matches `organize_before_judging`.
- `今日食咩` matches no pattern.
- Short generic aliases such as `具体` alone are not accepted as a lexicon phrase.

### Signal Recorder Tests

- Existing English and Chinese observation tests keep passing.
- A Cantonese pain-test message records `pain_test_for_product_scope`.
- A Cantonese direct-pushback message records `direct_pushback_when_wrong`.
- Replaying the same message still does not duplicate events.

### Prompt Provider Tests

- Cantonese input can inject a matching prompt hint even when token overlap is empty.
- English input that matches both alias and token overlap does not double count; the score uses `max`.
- Multiple aliases in one input produce one binary alias bonus.
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

The main risk is false positives from broad aliases. The phrase policy deliberately rejects short generic aliases to reduce that risk.

The second risk is missed detections from being stricter than the old keyword list. That is acceptable for v1 because missed weak learning is recoverable, while wrong learning silently changes prompt behavior.

The third risk is future drift if another developer adds aliases in one caller only. The shared lexicon invariant and tests should catch that.

## Implementation Notes

Use small, pure helpers. Do not introduce a protocol unless tests need injection. The lexicon should be easy to inspect in one file and should not depend on SQLite, LLM services, or `TurnPlanner`.

The first implementation should be a refactor plus caller wiring:

1. Add `ShadowPatternLexicon`.
2. Move aliases out of `ShadowLearningSignalRecorder`.
3. Inject or instantiate the lexicon in `ShadowLearningSignalRecorder`.
4. Use the same lexicon in `ShadowPatternPromptProvider`.
5. Add tests for CJK/Cantonese injection and false positives.

That is the whole scope.
