# Chat Markdown Structure (L2.5 fix)

**Date:** 2026-04-26
**Branch context:** `alexko0421/quick-action-agents` (L2.5 baseline — 4 commits on top of `replace-mentalhealth-with-plan`)
**Status:** Hard gate fix before Phase 1 (A+B) of strict-AI-agent phased plan

## Context

L2.5 ships per-mode `QuickActionAgent` contracts (Direction / Brainstorm / Plan). Live test on 2026-04-26 (conversation node `083D793F-605E-4C24-9FDC-04A325374EB7`, ~20:50–20:52 local) showed Plan mode failed to produce its contracted structured artifact across 6 user turns. Conversation degenerated into chat-style coaching that never delivered the "outcome / few moves / order / where you'll stall / today's first step" structure promised by `PlanAgent.contextAddendum` turn 2+.

Two failure layers were identified:

1. **Prompt compliance.** LLM (Sonnet 4.6 via OpenRouter) ignored the "Produce a structured plan" addendum across turns 2–4, kept emitting `<phase>understanding</phase>`, kept asking single follow-up questions.
2. **Renderer + paragraph normalization.** `MessageBubble` (`Sources/Nous/Views/ChatArea.swift:532`) renders message text as plain `Text(String)` — SwiftUI does not auto-render markdown for plain `String`. `normalizedParagraphs` (line 598) collapses single newlines to spaces, which destroys any line-based markdown structure (bullets, headers, table rows). Even if the LLM emitted `# Week 1\n- Mon: 20 min`, the user would see `# Week 1 - Mon: 20 min` as one run-on line of raw text.
3. **Architectural silent drop.** `PlanAgent.maxClarificationTurns = 4` — when reached, `turnDirective` returns `.complete` and mode drops with no final attempt to produce the artifact. Plan ends as ordinary chat, no structured output ever generated.

User feedback (2026-04-26): "Plan should produce a well-structured deliverable — what to do each Monday / Tuesday / Wednesday." Reference: a Claude.ai screenshot showing markdown headers, bullets, and a comparison table inside chat — the desired baseline. Confirmed scope: applies to all four modes (Direction / Brainstorm / Plan / default chat), not just Plan.

## Goals

- Chat bubbles render markdown headers, unordered bullets, and tables.
- Plan mode reliably produces a structured artifact with explicit format scaffold (outcome / weekly schedule as table / where you'll stall / today's first step).
- Brainstorm mode lists distinct directions as bullets, then prose-analyzes alive vs noise.
- Cap-turn behavior in Plan stops being silent — when `maxClarificationTurns` is reached, dispatcher injects a final "produce now" synthetic turn instead of dropping the mode.
- Default chat gains permission (via anchor.md) to use markdown structure when content has distinct items / schedules / data comparison.

## Non-goals

- Bold (`**`), italic (`*`), ordered lists (`1.`), inline code (`` ` ``), block quotes, code blocks. Out of scope for v1. Emphasis stays as 「」 per existing voice rule.
- New artifact surface (PlanCard / PlanDocument as a separate view from chat). That is the deferred option #3 from the trade-off discussion — independent product decision, not part of L2.5 fix.
- Phase 1 (tools + reasoning loop) of strict-AI-agent phased plan. Resumes after this fix passes live test.
- User-input markdown rendering. Only assistant bubbles render markdown; user bubbles stay plain text.

## Design

### A. Renderer

New file: `Sources/Nous/Views/ChatMarkdownRenderer.swift`. Internally reuses or evolves the parser from `Sources/Nous/Views/ScratchPadPanel.swift:245` (`MarkdownPreview`). If the existing parser cleanly supports headers + bullets and can be extended to tables, factor it into a shared component used by both `ScratchPadPanel` and the new chat renderer; otherwise, build the chat renderer fresh and leave `ScratchPadPanel` untouched.

Markdown subset:
- `#` and `##` headers — render as larger weighted text. Mapping to font sizes lives in the renderer file (suggest 16pt semibold for `#`, 15pt semibold for `##`; finalize during implementation).
- `-` unordered bullets — rendered as a SwiftUI `HStack` per row (bullet glyph + content) with consistent left padding.
- `|...|` GitHub-flavored markdown tables — header row + separator row (`|---|---|`) + data rows. Render as SwiftUI `Grid` (macOS 13+) or fall back to a manual `HStack`/`VStack` grid if `Grid` unavailable. Cell alignment from separator row syntax (`:---`, `:---:`, `---:`) deferred to v2 — v1 is left-aligned only.

Behavior:
- Markdown lines (those starting with `#`, `##`, `-`, or matching `|...|` table rows) are detected by line, not by full-document parse. The renderer walks the input line by line and groups runs into typed segments: heading, bullet block, table block, prose block.
- Prose segments still go through `Text(...)` and inherit existing styling (font 14, color `colaDarkText`, line spacing 8).
- Output is a `VStack(alignment: .leading)` of segment views with `assistantParagraphSpacing` (14) between segments.

`MessageBubble` (`Sources/Nous/Views/ChatArea.swift:551–596`) changes:
- Assistant branch (`else` at line 575): replace the `ForEach { Text(paragraph) }` body with a single call into `ChatMarkdownRenderer(text: parsedDisplayText)`.
- User branch (`if isUser` at line 557): unchanged. Still plain `Text(paragraph)`.
- Existing `assistantTextMaxWidth: 690`, padding, animation are preserved.

`normalizedParagraphs` (line 598) split out:
- Keep current behavior for the user branch (collapses soft breaks, joins lines within a paragraph).
- For the assistant branch, the new renderer takes the raw `parsed.displayText` directly — line-level structure must be preserved. The "single newline → space" collapse only applies inside prose segments, not across them.

To minimize churn, factor a new helper: `ChatMarkdownRenderer.parse(text: String) -> [Segment]` which is the single entry point. Old `normalizedParagraphs` stays as a private helper for the user branch only.

### B. Per-mode addendum revisions

`Sources/Nous/Models/Agents/DirectionAgent.swift` — **no change**. Direction is convergent prose; bullets would hurt the "narrow to one concrete next step" intent.

`Sources/Nous/Models/Agents/BrainstormAgent.swift` — `contextAddendum` turn 1+ gains an explicit format example after the existing "Generate genuinely distinct directions..." paragraph:

> 用 `-` bullet 列出 distinct directions（每条一行，简短一句 capture trade-off），跟住一段 prose 拆边样 feel alive、边样系噪音。

Lean memory policy unchanged. Markdown structure is content shape, orthogonal to memory injection.

`Sources/Nous/Models/Agents/PlanAgent.swift` — `contextAddendum` turn 2+ replaces the current bullet-list of requirements with an explicit format scaffold:

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

Turn 1 (decide-or-ask) addendum unchanged.

### C. anchor.md update

`Sources/Nous/Resources/anchor.md`, append to `# STYLE RULES` section (after line 149):

> 当内容有 distinct items / 周期 schedule / 数据对比，可以用 markdown 结构（`# 标题`、`- bullet`、`| table |`）。Emphasis 仍然用「」，唔好用 `**bold**`。

This is the first explicit ban on `**bold**` in anchor.md (memory previously claimed it was there — it wasn't). It is also the first explicit permission for markdown structure.

### D. Forced final turn (Plan cap)

`Sources/Nous/Models/Agents/QuickActionAgent.swift` — extend `QuickActionTurnDirective`:

```swift
enum QuickActionTurnDirective: Equatable {
    case keepActive
    case complete
    case completeWithFinalProduce  // new
}
```

`PlanAgent.turnDirective` change:

```swift
func turnDirective(parsed: ClarificationContent, turnIndex: Int) -> QuickActionTurnDirective {
    if turnIndex >= Self.maxClarificationTurns {
        return .completeWithFinalProduce  // was .complete
    }
    return parsed.keepsQuickActionMode ? .keepActive : .complete
}
```

Dispatcher integration (in `Sources/Nous/Services/TurnPlanner.swift` and/or `Sources/Nous/Services/TurnOutcomeFactory.swift` — exact split determined during implementation by reading the current dispatch flow):
- When a turn outcome carries `.completeWithFinalProduce`, the dispatcher synthesizes one additional assistant turn (rendered as a normal assistant bubble in the chat stream) before dropping `activeQuickActionMode`.
- The synthesized turn injects a final addendum (system-level, not visible in the bubble — only the resulting plan appears):

  > FINAL TURN: This is your last chance to produce the structured plan. The mode drops after this reply. Output the markdown sections (`# Outcome`, `# Weekly schedule` table, `# Where you'll stall`, `# Today's first step`) now using what you've learned from this conversation. No more clarifying questions.

- After this synthesized turn completes, `activeQuickActionMode` is set to nil.

Direction and Brainstorm continue to return `.complete` (no force needed — both are single-turn produce contracts already).

### E. Validation

After A+B+C+D land in one branch / one PR:

1. Build app, launch macOS Nous.
2. Open four fresh conversations and click each mode (or default chat). For each, confirm:
   - **Plan**: ask "我想开始跑步训练" (or similar). Expect output to contain `#` section headers and a `|...|` weekly schedule table that renders as a real table in the chat bubble.
   - **Brainstorm**: ask a divergent question (e.g. "我 startup 应该 pivot 边度"). Expect `-` bullet list of distinct directions followed by prose pattern analysis.
   - **Direction**: ask anything needing a single next step. Expect prose-dominant convergent reply. Markdown is permitted if natural, but Direction must not regress into a bullet list of equally-weighted options (that would defeat the convergent intent).
   - **Default chat**: ask a comparison question (e.g. "比较 swift concurrency 同 dispatch queue"). Expect `|...|` table to render.
3. Verify `<phase>understanding</phase>` marker still strips cleanly (no leak into rendered output).
4. Verify Plan cap behavior: provoke 4+ turns of clarification; confirm the synthesized "FINAL TURN" call fires once and produces the structured artifact.

Pass = all four modes show expected structure + Plan cap forces artifact + no marker leak. Hard gate releases, Phase 1 (A+B) design starts.

Regress = re-evaluate. Possible escalation: tighten prompts further, or revisit option #3 (separate artifact surface).

### F. Memory housekeeping (after ship)

Update `feedback_no_markdown_bold_in_chat`:
- Remove the stale claim "surgical anchor.md rule lives in STYLE RULES" (rule did not exist in anchor.md until this ship).
- Add: "2026-04-26 ship: anchor.md now permits markdown structure (`#`, `-`, `|`); ban on `**bold**` is now explicit in STYLE RULES; emphasis still uses 「」."

## Risks

- **Performance / layout cost of `Grid` table rendering.** macOS chat scroll performance with multi-row tables not yet measured. Implementation should sanity-check with a 7-row weekly schedule.
- **Brainstorm voice regression risk.** Adding bullet format guidance is a mode-addendum edit, not anchor.md edit, so `feedback_anchor_count_ceiling` does not directly apply — but voice impact still possible. Live-test confirms.
- **`MarkdownPreview` reuse vs fork.** If the existing scratchpad parser is too tightly coupled to its current presentation, factoring it out becomes the bigger risk than building chat-side fresh. Decide during implementation, defaulting to "build chat-side fresh and revisit dedup later" if reuse cost exceeds 2 hours.
- **Forced final turn UX.** A synthesized FINAL TURN may feel jarring if the user is mid-conversation. Mitigation: the addendum text is hidden from the user (it's a system-level instruction); only the resulting structured plan appears in the bubble. Verify no leakage during validation.

## Out of scope (explicitly deferred)

- Markdown for user bubbles
- Bold / italic / ordered list / code / quote / blockquote
- Cell alignment in tables
- Separate PlanCard / PlanDocument artifact surface (option #3 — independent product decision)
- Phase 1 (tools + reasoning loop) of strict-AI-agent — resumes after this fix passes live test
