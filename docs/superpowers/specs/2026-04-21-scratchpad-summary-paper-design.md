# ScratchPad: Summary → White-Paper Design

**Status:** Draft, awaiting user review
**Author:** Alex + Claude
**Date:** 2026-04-21
**Target files (primary):** `Sources/Nous/Views/ScratchPadPanel.swift`, `Sources/Nous/Services/ClarificationCardParser.swift`, `Sources/Nous/ViewModels/ChatViewModel.swift`, prompt anchor

---

## 1. Context

`ScratchPadPanel.swift` currently renders as a 300pt-wide glass sidebar with a free-typing markdown editor, persisted via `@AppStorage("nous.scratchpad.content")`. Toggled by the top-right `note.text` button in `ChatArea.swift:377-411`.

We want to transform it into a **white-paper document view** that displays an LLM-generated summary of the current chat, keeps the markdown editable, and exports as `.md`.

## 2. Goals

- User asks Nous in chat (e.g., "总结一下") → Nous emits a structured summary wrapped in `<summary>…</summary>`.
- Top-right `note.text` toggle (unchanged) opens the right-side panel.
- Panel renders the latest summary on a white-paper document visual (420pt wide, serif body, subtle shadow).
- User can still edit the markdown in-panel; unsaved edits are protected when a newer summary arrives.
- User downloads the panel content as `.md` via native macOS save dialog.

## 3. Non-Goals

- No new toggle button; no in-chat "open in paper" sticker.
- No summary history list (only the single latest summary is tracked; older ones are overwritten with protection).
- No two-way sync: editing the panel never touches the chat transcript, and the chat UI never re-renders from panel edits.
- No live-update summary (regenerate is user-driven, not continuous).

## 4. Core Flow

```
User         Nous (LLM)                 App state                Panel
 │               │                           │                       │
 │── "总结一下"──▶                           │                       │
 │               │──reply: <summary>…</>────▶                        │
 │               │                           │  latestSummary updated│
 │◀── chat shows (tag stripped) ──────────── │                       │
 │                                           │                       │
 │── tap top-right note.text toggle ────────▶                       │
 │                                           │ ── hand off to panel ─▶
 │                                           │                       │ (white paper renders)
 │                                           │                       │
 │── edit / tap "Download" ──────────────────────────────────────────▶ NSSavePanel
```

Invariants:

- No new UI affordance is added to the chat area; the only new surface is the LLM prompt instruction.
- Summary content source is always the **most recent** `<summary>…</summary>` block emitted by Nous in the current session.
- Chat bubble and panel are two render views of the same content; they do not mutate each other.

## 5. LLM Contract

### Prompt addition (anchor.md or prompt builder)

Append a new section instructing the model to wrap summary output in a tag. The exact wording will be drafted in the implementation plan; semantic content:

> When the user asks for a summary (keywords: "总结", "summarize", "repo", "做笔记", "summary", or equivalent intents), wrap the summary body in `<summary>…</summary>`. Inside, use this markdown structure:
>
> - `# {title}` — a concise topic title extracted from the conversation; used as the download filename.
> - `## 问题` — one narrative paragraph: what originally triggered the discussion.
> - `## 思考` — one narrative paragraph: the path the conversation took, including pivots.
> - `## 结论` — one narrative paragraph: consensus or decisions reached.
> - `## 下一步` — bullet list of actionable next steps.
>
> Paragraphs are narrative prose, not bullet dumps. Regular conversation text outside the tag is allowed (e.g., "整好了，睇下右边嘅白纸"); the summary itself must strictly live inside the tag.

### Parser contract (extend `ClarificationCardParser`)

Add these pure functions (no parser state change beyond new methods):

- `extractSummary(from raw: String) -> String?` — returns the inner markdown of the first well-formed `<summary>…</summary>` pair, or nil.
- `stripSummaryTags(from raw: String) -> String` — returns the raw string with the outer `<summary>` open/close tags removed but content preserved; used for chat-bubble rendering so users see the summary text inline.
- Existing `stripReasoning` (or equivalent) behavior is unaffected; `<thinking>` etc. continue to be stripped as before.

### ChatViewModel integration

On every completed assistant message:

1. Run `extractSummary` on the full assistant response text.
2. If non-nil, build a `ScratchSummary` (see §6) and publish it to a shared `ScratchPadStore`.
3. Separately, `stripSummaryTags` is applied for chat rendering (so the summary content remains visible in the bubble without the raw tag markup).

## 6. Data Model & State

### New types

```swift
struct ScratchSummary: Codable, Equatable {
    let markdown: String          // inner content of <summary>
    let generatedAt: Date
    let sourceMessageId: UUID     // assistant message this came from
}
```

### Store (new: `Sources/Nous/Services/ScratchPadStore.swift`)

An `@Observable` (or `ObservableObject`) singleton-ish store injected into the environment, owning the scratchpad state so both `ChatViewModel` (writer) and `ScratchPadPanel` (reader + editor) stay decoupled.

| Field | Type | Persistence | Purpose |
|---|---|---|---|
| `latestSummary` | `ScratchSummary?` | `@AppStorage("nous.scratchpad.latestSummary")` (JSON via a `Codable` wrapper) | Most recent summary emitted by Nous. |
| `currentContent` | `String` | `@AppStorage("nous.scratchpad.content")` (existing key, reused) | What the panel actually renders / edits. |
| `baseSnapshot` | `String` | `@AppStorage("nous.scratchpad.baseSnapshot")` | Exact string `currentContent` was set to at last load/download. `isDirty := currentContent != baseSnapshot`. |
| `contentBaseGeneratedAt` | `Date?` | `@AppStorage("nous.scratchpad.contentBaseDate")` | Which summary's `generatedAt` produced the current `baseSnapshot` (nil when content was free-typed without a summary). Used to detect "a newer summary is available". |
| `isDirty` | `Bool` | computed: `currentContent != baseSnapshot` | Shown as `•` in the header; gates the overwrite dialog. |
| `pendingOverwrite` | `ScratchSummary?` | in-memory only | Holds a newer summary waiting for the user's accept/reject decision. |

### Load logic (when panel becomes visible OR when `latestSummary` changes while panel is visible)

```
if latestSummary == nil:
    # Empty state; panel shows placeholder + free-typing editor (fallback).
    return

if contentBaseGeneratedAt == latestSummary.generatedAt:
    # User already loaded this summary; keep currentContent as-is.
    return

if !isDirty:
    currentContent = latestSummary.markdown
    baseSnapshot   = latestSummary.markdown
    contentBaseGeneratedAt = latestSummary.generatedAt
    return

# isDirty && newer summary available:
pendingOverwrite = latestSummary
# show confirm alert: "有新嘅 summary，要替换你嘅改动吗？" [替换 | 保留现有]
#   "替换"   → currentContent = pendingOverwrite.markdown
#              baseSnapshot   = pendingOverwrite.markdown
#              contentBaseGeneratedAt = pendingOverwrite.generatedAt
#              pendingOverwrite = nil
#   "保留"   → pendingOverwrite = nil
#              (contentBaseGeneratedAt unchanged → stays "behind latest";
#               next newer summary will re-prompt)
```

### Dirty semantics

`isDirty := currentContent != baseSnapshot`. Three transitions update `baseSnapshot`:

1. **Load** (silent or post-accept overwrite): `baseSnapshot = latestSummary.markdown; contentBaseGeneratedAt = latestSummary.generatedAt`.
2. **Download success**: `baseSnapshot = currentContent` (and leave `contentBaseGeneratedAt` untouched — a downloaded edit is clean relative to itself but still "behind" the latest summary, which is the desired behavior).
3. **First free-typed content while `latestSummary == nil`**: `baseSnapshot = currentContent` is updated continuously so `isDirty` stays false in empty-state (free typing isn't "dirty against a summary" — there is none). When the first summary arrives, it triggers the dirty path only if `currentContent` is non-empty AND differs from the incoming summary markdown.

## 7. Visual Design — The White Paper

### Panel shell

- Width: **420pt** (up from 300).
- Outer container: keep `NativeGlassPanel` at 32pt corner radius (consistent with Nous language).
- Inner "paper" body: new white surface inset inside the glass panel.

### Paper surface

| Attribute | Value |
|---|---|
| Background | `#FEFCF8` (warm off-white to reduce glare vs. pure `Color.white`) |
| Corner radius | 12pt (tighter than outer glass, document feel) |
| Shadow | `.shadow(color: .black.opacity(0.08), radius: 12, y: 4)` |
| Horizontal padding | 32pt |
| Vertical padding | 40pt |
| Body font | `.system(size: 14, design: .serif)` (New York on macOS) |
| Heading font | Serif, weights scaled by h-level (H1 20pt bold, H2 17pt semibold, H3 14pt semibold) |
| Monospaced spans (`` `code` ``) | Keep existing monospaced design |
| Line spacing | 6pt |

### Header row (above the paper)

- Left: `note.text` icon (colaOrange) + "白纸" title in serif bold.
- Middle: if `isDirty`, show dot `•` with label "未保存" in secondary color.
- Right, from left to right:
  1. "下载" button — SF Symbol `arrow.down.doc` + text.
  2. Existing Write / Preview toggle.
  3. Close X button (existing).

### Empty state (when `latestSummary == nil`)

- Centered serif small text: "想开始？喺左边同 Nous 倾一阵，叫佢『总结一下』。"
- Below: the existing `TextEditor` remains available so users can still free-type (this preserves today's scratchpad behavior as a graceful fallback). Free-typed content in this state is treated as a zero-base edit (i.e., `isDirty == false` until the first summary arrives).

## 8. Interactions

### Download

1. User taps "下载".
2. Compute default filename:
   - Extract first `# ` ATX heading from `currentContent`, trim, lowercase-safe slugify (keep CJK, strip `/\:*?"<>|` and control chars, collapse whitespace to `-`, trim to 60 chars).
   - If no heading or slug is empty, fall back to `Nous-Summary-{yyyy-MM-dd}.md` using today's local date.
3. Present `NSSavePanel` with:
   - `allowedContentTypes = [.init(filenameExtension: "md")!]`
   - `nameFieldStringValue = defaultFilename`
   - `canCreateDirectories = true`
4. On confirm: write `currentContent` as UTF-8, update `contentBaseGeneratedAt` to mark clean, show a toast `已保存到 {shortened path}` (if a toast mechanism exists; otherwise skip silently — do not add an NSAlert).
5. On cancel: no state change.

### Overwrite-protection dialog

Presented via SwiftUI `.alert` when `pendingOverwrite != nil`:

- Title: `有新嘅 summary`
- Message: `你喺白纸度仲有未下载嘅改动。要用新嘅 summary 替换吗？`
- Actions: `替换`（destructive style）, `保留现有`（cancel style, default）

### Write / Preview toggle

Existing behavior preserved. Both modes render inside the paper surface, so the visual frame stays identical whether editing or previewing.

## 9. Error & Edge Cases

| Case | Behavior |
|---|---|
| LLM forgets to wrap in `<summary>` | `latestSummary` unchanged; panel keeps current content. User can re-ask. |
| `<summary>` malformed (missing close tag, nested, truncated) | `extractSummary` returns nil (strict first-well-formed-pair parsing); treated as "no summary in this reply". |
| `<summary>` inner markdown has no `# ` heading | Render normally; filename falls back to the date-based default. |
| LLM emits multiple `<summary>` pairs in one reply | Extract only the first complete pair; ignore the rest. |
| User has `latestSummary == nil` and free-types | Treated as zero-base (not dirty). On first summary arrival, apply load logic; since `contentBaseGeneratedAt == nil` and `currentContent` is non-empty, treat as dirty → show overwrite dialog. |
| Panel opened while a new assistant reply is still streaming | Load logic runs on current `latestSummary`. If a new summary lands while panel is visible, re-run load logic (with dirty check) immediately. |
| Save dialog cancelled | No state change; dirty flag unchanged. |
| Write to chosen path fails (permissions, disk full) | Show an NSAlert with the error message; dirty flag unchanged. |
| User force-quits with dirty edits | Content is already persisted via `@AppStorage`; restored on next launch. Dirty computation re-evaluates against stored `contentBaseGeneratedAt`. |

## 10. Testing

### Unit tests (`Tests/NousTests/`)

- **`SummaryParserTests`** — against `ClarificationCardParser` extensions:
  - Extract single well-formed pair.
  - Extract first when multiple pairs exist.
  - Nil for unclosed / malformed / empty-body tag.
  - `stripSummaryTags` removes tags but preserves content, including when tag has surrounding whitespace / newlines.
- **`ScratchPadStoreTests`**:
  - Empty `currentContent` + no prior summary → first summary loads silently (no dialog, `isDirty == false` after).
  - Free-typed `currentContent` (non-empty) + no prior summary → first summary arrives → `pendingOverwrite` set, `currentContent` unchanged until user decision.
  - Same-base reload (`contentBaseGeneratedAt == latestSummary.generatedAt`) is a no-op.
  - Newer summary + clean content (`isDirty == false`) overwrites silently, updates `baseSnapshot` and `contentBaseGeneratedAt`.
  - Newer summary + dirty content sets `pendingOverwrite` without mutating `currentContent`.
  - Accepting overwrite updates `currentContent`, `baseSnapshot`, and `contentBaseGeneratedAt`; clears `pendingOverwrite`.
  - Rejecting overwrite leaves `currentContent`, `baseSnapshot`, and `contentBaseGeneratedAt` untouched; clears `pendingOverwrite`.
  - Download success sets `baseSnapshot = currentContent`; `isDirty` becomes false; `contentBaseGeneratedAt` is preserved.
- **`FilenameSlugTests`**:
  - Plain ASCII heading → slug.
  - CJK heading preserved.
  - Strips disallowed path characters.
  - Empty / whitespace heading → date fallback.
  - 60-char truncation boundary.

### Integration (view-model level; no UI harness needed)

- **`ChatViewModelSummaryTests`**: feed a fake assistant message containing `<summary>...</summary>` → assert `ScratchPadStore.latestSummary` is updated with matching `sourceMessageId` and `generatedAt` close to now; assert chat-visible text has the tags stripped but content present.

### Manual smoke checks (run before declaring done)

1. Ask Nous "总结一下" on a short chat → chat bubble shows summary text cleanly (no raw `<summary>` tag visible); panel opens to the same content on the white paper.
2. Edit the paper, ask Nous to summarize again → confirm dialog appears; "保留" keeps edits, "替换" adopts new summary.
3. Tap "下载" → NSSavePanel opens with h1-slug default name; saved file matches on-disk content.
4. Clear chat / new session → empty-state copy renders; free-typing still works.

## 11. Implementation Scope (targets for the plan)

Files expected to change:

- `Sources/Nous/Views/ScratchPadPanel.swift` — visual overhaul, header additions, empty state, dialog wiring.
- `Sources/Nous/Services/ClarificationCardParser.swift` — new `extractSummary` / `stripSummaryTags`.
- `Sources/Nous/Services/ScratchPadStore.swift` — **new file**, owns the state described in §6.
- `Sources/Nous/ViewModels/ChatViewModel.swift` — hook post-message processing to publish summaries + strip tags for chat rendering.
- `Sources/Nous/App/ContentView.swift` — inject `ScratchPadStore` into the environment; bind panel to it.
- Prompt source (anchor.md or its code builder) — add the `<summary>` instruction.
- `Tests/NousTests/` — new test files per §10.

Out of scope for this spec:

- Multiple-summary history browsing.
- Syncing panel edits back into the chat transcript.
- Non-macOS targets.
- Rich-text editing inside the paper (markdown stays source-of-truth).
