# Chat Markdown Structure (L2.5 fix)

**Date:** 2026-04-26
**Branch context:** `alexko0421/quick-action-agents` (L2.5 baseline — 4 commits on top of `replace-mentalhealth-with-plan`)
**Status:** Hard gate fix before Phase 1 (A+B) of strict-AI-agent phased plan
**Spec version:** v5 (post-codex round 4 — 3 spec-consistency fixes from v4)

## Context

L2.5 ships per-mode `QuickActionAgent` contracts (Direction / Brainstorm / Plan). Live test on 2026-04-26 (conversation node `083D793F-605E-4C24-9FDC-04A325374EB7`, ~20:50–20:52 local) showed Plan mode failed to produce its contracted structured artifact across 6 user turns. Conversation degenerated into chat-style coaching that never delivered the "outcome / few moves / order / where you'll stall / today's first step" structure promised by `PlanAgent.contextAddendum` turn 2+.

Three failure layers were identified:

1. **Renderer + paragraph normalization.** `MessageBubble` (`Sources/Nous/Views/ChatArea.swift:532`) renders message text as plain `Text(String)` — SwiftUI does not auto-render markdown for plain `String`. `normalizedParagraphs` (line 598) collapses single newlines to spaces, which destroys any line-based markdown structure (bullets, headers, table rows). Even if the LLM emitted `# Week 1\n- Mon: 20 min`, the user would see `# Week 1 - Mon: 20 min` as one run-on line of raw text.
2. **Cap-trigger arrives post-hoc.** `PlanAgent.maxClarificationTurns = 4` — the directive runs *after* the model already generated a turn under the normal production contract. The cap then silently drops the mode without ever asking the model to produce. Plan ends as ordinary chat, no structured output ever generated.
3. **Prompt strength.** Even before the cap, the LLM (Sonnet 4.6 via OpenRouter) ignored "Produce a structured plan" across turns 2–4, kept emitting `<phase>understanding</phase>`, kept asking single follow-up questions. The current addendum is too soft.

User feedback (2026-04-26): "Plan should produce a well-structured deliverable — what to do each Monday / Tuesday / Wednesday." Reference: a Claude.ai screenshot showing markdown headers, bullets, and a comparison table inside chat — the desired baseline. Confirmed scope: applies to all four modes (Direction / Brainstorm / Plan / default chat), not just Plan.

### v5 changes from v4 (post-codex round 4)

Round 4 found 3 spec-consistency issues (no new architecture problems). v5 fixes:

- **Removed contradicted underscore regex bullets** from "Sanitization of unsupported markdown" — v4 declared underscore italic out of scope but the parsing-model section still listed `__...__` / `_..._` regexes. v5 deletes those lines so the spec is internally consistent.
- **Clarified unclosed-fence fallback semantics.** v4 said "captured content renders as regular prose segments" but the test expected `# Header` / `- bullet` inside the captured content to render as structure. v5 specifies: captured content is **re-fed to normal line-parsing**, so headings / bullets / tables inside the orphaned fence ARE recognized as structure; only the bare opening `` ``` `` delimiter line falls through as a literal prose segment. Test expectation aligned.
- **Corrected the SwiftUI single-parse claim.** v4 wrote "SwiftUI memoizes the computed property per body recompute" — this is false. Swift computed properties re-evaluate on every access; SwiftUI does not memoize them. v5 specifies an `AssistantBubbleContent` helper view that binds `let segments = ChatMarkdownRenderer.parse(displayText)` once inside its `body`, then passes `segments` to both the renderer and `.animation(value: segments.count)`. This guarantees a single parse per body recompute through Swift's `let` binding, not through any SwiftUI magic.

### v4 changes from v3 (post-codex round 3)

Round 3 confirmed 2/5 round-2 findings ADDRESSED, 3 PARTIAL. v4 micro-fixes:

- **Drop underscore italic from v1.** Round 3 [P2]: `_..._` rule corrupts `snake_case_var`. Adding identifier-boundary guards is fragile. Drop `_..._` and `__...__` from sanitization scope; v1 only handles `**bold**`, `*italic*` (asterisk), `` `code` ``, ordered list prefixes, quote prefixes. Underscore italic is rare in Cantonese voice anyway.
- **Unclosed fence falls back to prose during streaming.** Round 3 [P2]: an incomplete `` ``` `` (mid-stream or LLM-omitted close) would swallow all following content into `Segment.verbatim`. v4 specifies: parser tracks fence-open state. If parsing reaches EOF without closing fence, the opening `` ``` `` line and all captured content render as **regular prose segments** (sanitized as usual), not verbatim. This makes streaming safe — partial fences look like prose until the close arrives.
- **Borderless GFM tables explicitly out of scope.** Round 3 [P2]: GFM allows `col | col` without outer pipes. v4 narrows the spec: v1 only recognizes pipe-bordered tables `| col | col |`. Borderless input falls through to prose. Documented in non-goals.
- **Single-parse architecture in MessageBubble.** Round 3 [P2]: `.animation(value: ChatMarkdownRenderer.parse(text).count)` plus renderer-internal parse = double parse per body recompute. v4 changes MessageBubble shape: a computed property `assistantSegments: [Segment]` parses once. `ChatMarkdownRenderer` takes `[Segment]` directly (no internal parse). `.animation(value: assistantSegments.count)` references the same computed value SwiftUI already memoizes per body recompute.

### v3 changes from v2 (post-codex round 2)

Codex round 2 confirmed v2 addressed 8/12 v1 findings; 4 PARTIAL plus 1 new P1 + 4 new P2 surgical issues. v3 fixes:

- **Plan cap range, not exact-match.** v2's `case Self.maxClarificationTurns:` only matches turn 4. Any race / persistence / parser edge that lets Plan survive to turn 5+ would resume normal contract. v3 uses Swift open-ended range `case Self.maxClarificationTurns...:` so cap fires for any turn ≥ cap.
- **Sanitization strips balanced pairs only.** v2's "single regex pass to strip `*`, `_`, backticks" would damage `int *p`, `*.swift`, `3 * 4`, escaped delimiters, mixed Cantonese / English code. v3 strips only when delimiters appear in **matched pairs** within a single line; unmatched literals are preserved. Line-start prefixes (ordered-list `\d+\. `, quote `> `) still strip unconditionally.
- **Code fence content is verbatim, not sanitized.** v2 said fence inner content renders as prose, but the prose sanitizer would then strip backticks/asterisks inside the fence — silently corrupting code examples. v3 adds a `verbatim` segment type: fence content bypasses sanitization entirely (still renders in chat font, no syntax highlighting).
- **Table separator parsed by split-then-validate, not single regex.** v2's regex `^\|[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)+\|$` rejects standard GFM separators like `| --- | --- |` because it doesn't allow whitespace after every internal pipe consistently. v3 splits the line on `|` (respecting `\|` escape), trims each cell, and validates each cell against `^:?-+:?$`. More robust against legitimate GFM spacing variations.
- **Animation value gated on segment count.** v2 uses `.animation(value: assistantDisplayText)` — every streaming token mutates the String, triggering full markdown reparse + Grid reconstruction on each delta. v3 uses `.animation(value: assistantSegments.count)` so animation fires only on structural changes (a new heading / bullet / table appearing), not on prose growing token-by-token. The renderer still re-parses on text change (computed property) but SwiftUI's animation diff stays cheap.

### v2 changes from v1 (post-codex round 1)

Codex review of v1 returned FAIL (5 P1 / 6 P2). v2 addresses every finding:

- **anchor.md is frozen** per `AGENTS.md:39, 131` — markdown permission relocates to `ChatViewModel.assembleContext` volatile layer instead of editing anchor.md. v1 violated this rule.
- **Forced-final-turn replaced with cap-aware addendum.** v1 proposed a synthetic post-hoc retry turn requiring a new `QuickActionResolution` outcome type, TurnExecutor changes, and dual-dispatch coverage. Cleaner fix: `PlanAgent.contextAddendum` returns a FINAL-urgent variant *at* the cap turn so the model receives the right contract pre-execution, no retry needed. Zero dispatcher changes.
- **Markdown unknown-element behavior is now defined** (strip delimiters, render content as plain text).
- **MarkdownPreview is forked, not reused** — scratchpad parser supports a different subset (`**bold**`, `*italic*`, headings up to h4) and shouldn't be coupled.
- **Renderer split is concrete** — `paragraphTexts` divides into `userParagraphTexts` (existing normalization) and `assistantSegments` (new).
- **Table parsing strictness defined** — header + separator + ≥1 row, fall back to prose otherwise.
- **`ClarificationCardParser <summary>` interaction tested** — summary text is now also rendered through the new chat markdown renderer; tests cover that.
- **Brainstorm bullet constraint added** to prevent listicle voice regression.
- **Unit tests enumerated** for renderer, table parser, agent addendum-at-cap, parser+renderer integration.

A deferred true-synthetic-final-turn (option C from the brainstorming session) is out of scope for v1 — only added as v2 backstop if the cap-aware addendum still gets ignored by the LLM.

## Goals

- Chat bubbles render markdown headers, unordered bullets, and tables.
- Unsupported markdown (`**bold**`, `*italic*`, backticks, ordered lists) renders as plain text with delimiters stripped — never raw `**` artifacts.
- Plan mode reliably produces a structured artifact: explicit format scaffold (outcome / weekly schedule as table / where you'll stall / today's first step).
- Brainstorm mode lists distinct directions as short bullet labels with tradeoffs, then prose-analyzes alive vs noise.
- Cap-turn behavior in Plan stops being silent + post-hoc — at `turnIndex == maxClarificationTurns`, the addendum returned to the model *before generation* is the FINAL urgent variant, not the normal production contract.
- Default chat gains permission (via `assembleContext` volatile layer) to use markdown structure when content has distinct items / schedules / data comparison.

## Non-goals

- Bold (`**`), italic (`*`), ordered lists (`1.`), inline code (`` ` ``), block quotes, code blocks (rendered as code). Out of scope for v1 *as renderable structures*. Emphasis stays as 「」 per existing voice. Unsupported markdown is sanitized to plain text (see Goals).
- Underscore italic (`_text_`, `__text__`). Identifier collision risk (`snake_case`, `__init__`) is too high; v1 leaves underscores literal.
- Borderless GFM tables (`col | col` without leading and trailing pipe). Only pipe-bordered tables `| col | col |` are recognized; borderless input falls through to prose.
- Editing `anchor.md`. Per `AGENTS.md:39`, anchor is frozen.
- A separate PlanCard / PlanDocument artifact surface (option #3 from brainstorming — independent product decision).
- A synthetic forced-produce turn injected post-hoc (option C from brainstorming — deferred to v2 if cap-aware addendum proves insufficient).
- Phase 1 (tools + reasoning loop) of strict-AI-agent phased plan. Resumes after this fix passes live test.
- User-input markdown rendering. Only assistant bubbles render markdown; user bubbles stay plain text.

## Design

### A. Renderer

New file: `Sources/Nous/Views/ChatMarkdownRenderer.swift`. **Built fresh, not reusing `ScratchPadPanel.MarkdownPreview`** — scratchpad's parser supports a different subset (bold, italic, code, h1–h4, `*` bullets) and coupling them risks dragging chat into scratchpad's regressions or vice versa. Dedup can be revisited later if both grow toward a shared subset.

Markdown subset (rendered as structure):

- `#` and `##` headers — render as larger weighted text. Suggested 16pt semibold for `#`, 15pt semibold for `##`; finalize during implementation.
- `-` unordered bullets — rendered as `HStack` per row (bullet glyph + content) with consistent left padding.
- `|...|` GitHub-flavored markdown tables — rendered as SwiftUI `Grid` (macOS 13+; the app's deployment target already supports this, verify during implementation). Cell alignment from separator row syntax (`:---`, `:---:`, `---:`) deferred to v2 — v1 is left-aligned only.

Markdown subset (sanitized to plain text, NOT rendered as structure):

- `**text**` (bold) — strip delimiters when they appear as a **matched pair within a single line**. Unmatched single `*` is preserved literally (so `int *p`, `*.swift`, `3 * 4` stay intact).
- `*text*` (italic asterisk) — same balanced-pair rule.
- `` `text` `` (inline code) — same balanced-pair rule for backticks.
- `1. text`, `2. text` (ordered list) → strip the leading `^\d+\.\s+` prefix; render `text` as a regular prose line. Always strips (line-start prefix, no balancing).
- Block quotes (`> text`) → strip leading `^>\s+`; always strips.

**Underscore italic (`_text_`, `__text__`) is explicitly NOT sanitized in v1.** Identifier overlap (`snake_case_var`, `__init__`, etc.) makes any boundary heuristic fragile. If an LLM emits `_emphasis_` it will render literally with underscores visible. Acceptable tradeoff: the Cantonese voice rule biases away from underscore italic anyway, and identifier preservation is the higher-value invariant.

Code fence behavior (separate segment type — see `Segment.verbatim` below):

- ```` ``` ```` opens a verbatim block. Inner content is captured **as-is** (no sanitization, no delimiter stripping) until the closing ```` ``` ````. Fence delimiter lines themselves are dropped from output. The verbatim segment renders in the same chat font as prose; no syntax highlighting.
- Fenced content does NOT pass through the prose sanitizer — code examples like `` `foo` ``, `int *p`, `i++ * 2` survive verbatim inside fences.
- **Unclosed fence (EOF before closing `` ``` ``):** parser falls back — the opening `` ``` `` line itself renders as a literal prose segment, and **the captured content is re-fed to normal line-parsing** (so headings, bullets, tables inside the orphaned fence ARE recognized as structure). This is essential during streaming, when a partial response may have an open fence that hasn't been closed yet. Without this fallback, an in-progress fence would swallow all subsequent text into verbatim, breaking the live-rendered structure. The close-arrives-later transition (re-parsed-as-structure → verbatim block) animates via segment-count change like any other structural shift.

Rationale: an LLM under a Cantonese stoic voice contract will occasionally emit `**emphasis**` or `1. item` despite the soft 「」 rule. Showing raw `**` is a visible regression. Stripping only **balanced** delimiters preserves legitimate technical prose. Code fences as a verbatim segment guarantee the only safe place for code examples is intact.

#### Table parsing strictness

v1 only recognizes **pipe-bordered** tables (leading and trailing `|`). GFM also permits borderless tables like `col | col` / `--- | ---` — these are explicitly out of scope for v1; borderless input falls through to prose. Documented in non-goals.

A `|...|` block becomes a table only if **all** of:

1. The first row is a pipe-bordered header row: `| col | col |` with ≥2 cells. Lines without leading and trailing `|` do not start a table.
2. The second row is a separator row. Validation is **split-then-validate**, not a single regex:
   - Split the line by `|` (respecting `\|` as escape — temporarily replace `\|` with a sentinel before split, restore after).
   - Drop empty leading and trailing fields produced by the bordering pipes.
   - Trim whitespace from each remaining field.
   - Each trimmed field must match `^:?-+:?$` (allows `---`, `:---`, `:---:`, `---:`).
   - The number of separator fields must equal the header column count.

   This handles `| --- | --- |`, `|---|---|`, `| :--- | ---: |`, and other GFM-legal spacing variations that the earlier single-regex approach would have rejected.
3. At least one data row follows.
4. Data row column count: data rows are split using the same escape-aware pipe-split rule. Right-pad with empty cells if short; truncate if too long. Pure prose containing `|` (not flanked by markdown table structure) renders as prose.

If any condition fails, the entire candidate block falls back to prose rendering (each line as a separate paragraph through the unsupported-markdown sanitizer above).

Escape: `\|` in cell content renders as literal `|`, not a column separator.

#### Renderer parsing model

`ChatMarkdownRenderer.parse(text: String) -> [Segment]` walks input line-by-line and groups runs into typed segments:

```swift
enum Segment {
    case heading(level: Int, text: String)
    case bulletBlock([String])         // each string is one bullet's content
    case table(headers: [String], rows: [[String]])
    case prose(String)                 // multi-paragraph prose, sanitized
    case verbatim(String)              // fenced code, NOT sanitized
}
```

Output is a `VStack(alignment: .leading)` of segment views with `assistantParagraphSpacing` (14) between segments. Each segment internally uses font 14, color `colaDarkText`, line spacing 8 (matching current assistant prose style).

**Sanitization of unsupported markdown is balanced-pair only, and only for asterisk delimiters:**

- Strip `**...**` only when both delimiters present in the same line: regex `\*\*([^\*]+)\*\*` → `$1`.
- Strip `*...*` only when balanced (same line, content non-empty): `(?<!\*)\*([^\*\s][^\*]*?)\*(?!\*)` → `$1` (negative lookbehind/lookahead avoids interfering with `**bold**`).
- Strip `` `...` `` (inline code) only when balanced: `` `([^`]+)` `` → `$1`. Verify `int *p` (no balanced `*`), `*.swift` (`*` followed by non-`*`), `3 * 4` (spaces around `*`), `if (n > 0) {` (no `*`) all pass through unchanged.
- Strip line-start `^\d+\.\s+` and `^>\s+` unconditionally (these are positional markers, no balancing needed).
- **Underscores `_` are NEVER stripped.** Per non-goals, underscore italic (`_text_`, `__text__`) is out of scope for v1 to preserve `snake_case_var`, `__init__`, etc. If the LLM emits underscores, they render literally.

Verbatim segments skip sanitization entirely — fenced code renders as captured.

#### `MessageBubble` integration

`MessageBubble` (`Sources/Nous/Views/ChatArea.swift:532`) currently has a single computed property `paragraphTexts` (line 543) that runs `normalizedParagraphs` unconditionally before the user/assistant branch.

**Refactor:** split user / assistant rendering into separate paths, and extract the assistant body into a helper view so a single `let segments` binding ensures one parse per body recompute.

```swift
private var userParagraphTexts: [String] {
    Self.normalizedParagraphs(from: text)
}

private var assistantDisplayText: String {
    ClarificationCardParser.parse(text).displayText
}

// MessageBubble.body switches on isUser:
// - isUser == true (line 557 area): unchanged — ForEach over userParagraphTexts rendering each via Text(...).
// - isUser == false: render AssistantBubbleContent(displayText: assistantDisplayText)

private struct AssistantBubbleContent: View {
    let displayText: String

    var body: some View {
        // Single parse per body recompute — Swift `let` binding, no SwiftUI memoization assumed.
        let segments = ChatMarkdownRenderer.parse(displayText)
        return ChatMarkdownRenderer(segments: segments)
            .frame(maxWidth: assistantTextMaxWidth, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .animation(.easeOut(duration: 0.15), value: segments.count)
    }
}
```

Why a helper view rather than a computed property: Swift computed properties re-evaluate on every access. SwiftUI does not memoize them. If `assistantSegments` were accessed in both the renderer and the `.animation(value:)` modifier, parsing would happen twice per body recompute. The helper view's `let segments = ...` binding inside `body` evaluates exactly once and is shared by both downstream references.

Existing `assistantTextMaxWidth: 690` and padding are preserved. Streaming a single growing prose segment produces no animation churn (count stays 1); a new heading / bullet block / table appearing animates once when its segment is added.

Old `normalizedParagraphs` stays as a private static helper used only by `userParagraphTexts`.

### B. Per-mode addendum revisions

`Sources/Nous/Models/Agents/DirectionAgent.swift` — **no change**. Direction is convergent prose; bullets would hurt the "narrow to one concrete next step" intent. Direction inherits markdown permission from the global `assembleContext` policy (section C) but is not pushed to use it.

`Sources/Nous/Models/Agents/BrainstormAgent.swift` — `contextAddendum` turn 1+ gains an explicit format constraint after the existing "Generate genuinely distinct directions..." paragraph:

> 用 `-` bullet 列出 distinct directions，每条 bullet 系**短 label + 一句 trade-off**（唔可以系完整段落），跟住一段**唔用 bullet 嘅 prose** 拆边样 feel alive、边样系噪音。Bullet block 唔可以等权列 options——读者一眼睇到嘅唔系「四个并列选项」，而系「四条方向加一段判断」。

Lean memory policy unchanged. The "short label + tradeoff + prose judgment" framing addresses Codex P2: bullet hybrid risks flattening into a Direction-style options list if bullets are full sentences.

`Sources/Nous/Models/Agents/PlanAgent.swift` — two changes:

1. `contextAddendum` turn 2 onward replaces the current bullet-list of requirements with an explicit format scaffold using markdown the renderer now supports.
2. `contextAddendum` is **cap-aware** — when `turnIndex == maxClarificationTurns`, return a FINAL-urgent variant *instead of* the normal production contract. This addresses Codex P1 #5 (post-hoc cap timing) — the model receives the right contract before generating, not after.

```swift
func contextAddendum(turnIndex: Int) -> String? {
    switch turnIndex {
    case 0:
        return nil
    case 1:
        return decideOrAskAddendum  // unchanged from current
    case Self.maxClarificationTurns...:
        return finalUrgentAddendum  // NEW — fires for turn == cap AND any turn > cap (defensive)
    default:
        return normalProductionAddendum  // existing turn 2+ contract, with format scaffold
    }
}
```

The open-ended range `Self.maxClarificationTurns...` ensures the FINAL urgent contract fires for turn 4 **and** any later turn (5, 6, ...) if the mode survives past cap through any race / persistence / parser edge. `turnDirective` still returns `.complete` at turn 4 so mode normally drops, but the addendum is defensive against the edge case where it doesn't.

`normalProductionAddendum` (turn 2+ but not at cap):

```
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
```

`finalUrgentAddendum` (turn == cap):

```
PLAN MODE — FINAL TURN:
This is your last chance to produce the plan. Mode drops after this reply.
You may NOT ask another clarifying question. Output the four markdown sections
now using whatever you have learned so far:

# Outcome
# Weekly schedule (use the | table | format)
# Where you'll stall
# Today's first step

Drop the <phase>understanding</phase> marker. Stay specific.
```

`turnDirective` keeps its current shape — no new enum case, no synthetic turn, no dispatcher changes. At cap, it returns `.complete` (mode drops *after* this generation, which is the FINAL one).

### C. Markdown permission via `assembleContext` (replaces v1's anchor.md edit)

`Sources/Nous/ViewModels/ChatViewModel.swift:812` (`assembleContext`) gains a new volatile context piece, prepended to `volatilePieces` so it's seen by every turn regardless of mode (default chat, Direction, Brainstorm, Plan):

```
CHAT FORMAT POLICY:
当内容有 distinct items / 周期 schedule / 数据对比，可以用 markdown 结构（`# 标题`、
`- bullet`、`| table |`）呈现。Emphasis 仍然用「」，唔好用 `**bold**` / `*italic*` / 倒勾。
```

Placement: as the first or second piece in `volatilePieces` (before any memory / citations / quick-action addendum). Ordering matters because LLMs weight earlier instructions more. Must come *after* the "ACTIVE QUICK MODE" line is appended? No — it's a global format policy independent of mode, so first-piece placement is correct.

Why not anchor.md: `AGENTS.md:39` and `:131` mark anchor as frozen. v1's plan to add a STYLE RULES line to anchor was a violation caught by codex review. Volatile context layer is the correct seam for chat-format policy.

### D. (Removed in v2)

The v1 D section ("Forced final turn / `.completeWithFinalProduce`") is replaced by the cap-aware `PlanAgent.contextAddendum` in section B. No dispatcher / `TurnExecutor` / `QuickActionTurnDirective` changes. If post-ship live test reveals the LLM still ignores even the FINAL-urgent contract, a true synthetic forced-produce turn (with the architectural depth Codex flagged in v1 P1 #2/#3/#4) becomes the v2 backstop — but only after empirical evidence of need.

### E. Validation

After A+B+C land in one branch / one PR:

#### Unit tests (new)

- `ChatMarkdownRendererTests` — covers `parse(text:)` returning expected `[Segment]` for: heading-only input, bullet-only input, table-only input, prose-only input, fenced-code-only input, mixed input.
- `ChatMarkdownRendererTests` sanitization (balanced-pair):
  - `**bold**` strips to `bold`, `*italic*` strips to `italic`, `` `code` `` strips to `code`.
  - `1. item` strips leading `1. ` to `item`. `> quote` strips leading `> ` to `quote`.
  - **Preserves**: `int *p` (single `*`, unbalanced), `*.swift` (`*` not paired before whitespace), `3 * 4` (spaces around `*`), `if (n > 0)` (unbalanced `>`), `snake_case_var` (underscore italic NOT sanitized, identifier intact), `__init__` (double underscore NOT sanitized), `_leading_underscore` (literal), inline mention of literal `**` without text between (`a ** b` if `**` would have to cross word boundaries — depends on regex; explicit test).
  - Fenced code block content survives verbatim — input `` ```\nint *p = `foo`;\n``` `` produces a `Segment.verbatim("int *p = `foo`;")`, no stripping.
  - **Unclosed fence fallback**: input `` ```\nint *p\n# Header\n- bullet `` (no closing fence) parses with the bare `` ``` `` line as a literal prose segment AND the captured content re-fed to normal line parsing — so `int *p` becomes a prose segment, `# Header` becomes a heading segment, `- bullet` becomes a bullet block segment. NOT a single verbatim segment swallowing all 4 lines.
- `ChatMarkdownRendererTests` table strictness:
  - Standard `| a | b |\n| --- | --- |\n| 1 | 2 |` parses as table.
  - `| a | b |\n|---|---|\n| 1 | 2 |` (no inner whitespace) parses as table.
  - `| a | b |\n| :--- | ---: |\n| 1 | 2 |` parses as table (alignment markers tolerated even though v1 ignores alignment).
  - Table with no separator row falls back to prose.
  - Ragged column counts normalize (right-pad short rows, truncate long rows).
  - Escaped `\|` in cell content renders as literal `|`, not a column separator.
  - Pipe in regular prose like "use `cmd | grep foo`" with no header / separator row rendering does NOT trigger table parsing.
  - **Borderless GFM input** `col | col\n--- | ---\n1 | 2` (no leading/trailing pipes) does NOT parse as a table — falls through to prose. Documented out of scope.
- `PlanAgentTests` (extend existing `QuickActionAgentsTests`) — `contextAddendum(turnIndex:)` returns the right addendum at each turn: 0 → nil, 1 → decideOrAsk, 2 / 3 → normal production, `maxClarificationTurns` (4) → final urgent, **`maxClarificationTurns + 1` and `+ 2` (5, 6) also → final urgent** (defensive range pattern coverage). Verify final urgent contains "FINAL TURN" sentinel and table format hint.
- `BrainstormAgentTests` — addendum at turn 1+ contains the new "短 label + tradeoff + prose judgment" constraint string.
- `ClarificationCardParserTests` (extend existing) — input containing `<summary>` with markdown inside (headers, bullets, table) returns `displayText` that preserves the inner markdown intact (no whitespace mangling, no marker leak).

#### Manual live tests

Build app, launch macOS Nous. Open four fresh conversations and click each mode (or default chat). For each, confirm:

- **Plan**: ask "我想开始跑步训练" (or similar). Expect output to contain `#` section headers and a `|...|` weekly schedule table that renders as a real table in the chat bubble.
- **Plan cap**: provoke 4+ clarification turns (avoid giving complete info). Confirm: at turn 4 the assistant produces the structured plan (FINAL urgent contract activated pre-execution, not after a wasted turn). No duplicate assistant replies.
- **Brainstorm**: ask a divergent question (e.g. "我 startup 应该 pivot 边度"). Expect short `-` bullet labels with tradeoffs followed by prose pattern analysis. Verify bullets do not look like equally-weighted options.
- **Direction**: ask anything needing a single next step. Expect prose-dominant convergent reply. Markdown is permitted if natural, but Direction must not regress into a bullet list of equally-weighted options.
- **Default chat**: ask a comparison question (e.g. "比较 swift concurrency 同 dispatch queue"). Expect `|...|` table to render.
- **Marker leak check**: verify `<phase>understanding</phase>` and `<summary>` tag markers still strip cleanly. No raw `**` / `*` / backticks visible anywhere across all test conversations.

Pass = unit tests green + all four modes show expected structure + Plan cap forces artifact pre-execution + no marker leak. Hard gate releases, Phase 1 (A+B) of strict-AI-agent phased plan resumes.

Regress = re-evaluate. If the cap-aware FINAL urgent addendum still gets ignored by the LLM, escalate to the deferred true synthetic forced-produce turn (option C from brainstorming, with the full architectural treatment Codex flagged: new outcome type, dispatcher changes, dual-path coverage, persistence/hide/embedding semantics).

### F. Memory housekeeping (after ship)

Update `feedback_no_markdown_bold_in_chat`:

- Remove the stale claim "surgical anchor.md rule lives in STYLE RULES" — the rule never existed in anchor.md; Nous voice naturally avoided `**bold**` from anchor.md's overall tone, not from an explicit ban.
- Add: "2026-04-26 ship: chat format policy lives in `ChatViewModel.assembleContext` volatile layer; permits `# headers`, `- bullets`, `| tables |`; emphasis still uses 「」; unsupported markdown is sanitized in `ChatMarkdownRenderer` (delimiters stripped, content kept)."

Add new memory `project_anchor_is_frozen`:

- "`AGENTS.md:39, 131` mark `Sources/Nous/Resources/anchor.md` as frozen. Do not edit. Voice / format / behavior changes that look like they belong in anchor go into `ChatViewModel.assembleContext` volatile layer or per-agent `contextAddendum` instead. Caught 2026-04-26 by codex review of v1 of this spec."

## Risks

- **Performance / layout cost of `Grid` table rendering.** macOS chat scroll performance with multi-row tables not yet measured. Implementation should sanity-check with a 7-row weekly schedule.
- **Brainstorm voice regression risk.** Adding bullet format guidance is a mode-addendum edit, not anchor.md edit, so `feedback_anchor_count_ceiling` does not directly apply — but voice impact still possible. Live-test confirms.
- **Sanitization over-strips.** A user's prose containing literal `*` in Cantonese context (rare but possible in technical discussion: "C 嘅 `int *p`") could lose its asterisk. Acceptable for v1 — emphasis is the dominant LLM use of `*`, and the bug is recoverable by the user re-quoting with backticks (which would also be stripped, but conveying intent).
- **Cap-aware addendum still ignored.** If the LLM ignores even the FINAL urgent contract, we're back to silent degradation. Mitigation: live test specifically for cap behavior; backstop is the deferred true synthetic turn (option C).
- **Animation value change.** Switching `.animation(value:)` to `segments.count` (bound by `let` inside the `AssistantBubbleContent` helper view) makes animation fire only on segment count changes (new heading / bullet block / table appearing) — much fewer animations than v2's per-token approach. Single parse per body recompute via Swift `let` binding (Swift computed properties are NOT memoized by SwiftUI; the helper-view + `let` pattern is what guarantees one parse). Test once with a long Plan response under streaming to confirm no janky flashes when a table block first appears.
- **Sanitization regex backtracking.** Balanced-pair regexes with negative lookbehind/lookahead can hit catastrophic backtracking on adversarial input (e.g. very long lines of `*`). Add a fuzz test or input length cap (e.g. skip sanitization on lines > 4 KB) as defensive guardrail.
- **`<summary>` interaction.** Long-form summaries that previously rendered as plain prose now render with markdown structure. This is a behavior change for the scratchpad-summary surface in chat. Tests cover the parse-through; manually verify a previously-summarized conversation still looks reasonable.

## Out of scope (explicitly deferred)

- Markdown for user bubbles
- Bold / italic / ordered list / code / quote / blockquote *rendered as structure* (sanitized to plain text instead)
- Cell alignment in tables (left-aligned only in v1)
- Separate PlanCard / PlanDocument artifact surface (option #3 — independent product decision)
- True synthetic forced-produce turn (`QuickActionResolution` outcome type, dispatcher changes, TurnExecutor allowing assistant-only execution, dual-path coverage, persistence/hide/embedding semantics) — only if cap-aware addendum proves insufficient post-ship
- Phase 1 (tools + reasoning loop) of strict-AI-agent — resumes after this fix passes live test
