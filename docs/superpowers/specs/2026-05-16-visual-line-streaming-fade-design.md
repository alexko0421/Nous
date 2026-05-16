# Visual-Line Streaming Fade - Design

**Date:** 2026-05-16
**Status:** Approved direction from visual calibration; awaiting user review of this written spec.
**Scope:** Assistant reply rendering in `Sources/Nous/Views/ChatArea.swift` and `Sources/Nous/Views/ChatMarkdownRenderer.swift`.
**Non-scope:** LLM streaming cadence, provider behavior, message persistence, `anchor.md`, tables, code blocks, and user bubbles.

## Problem

Assistant replies currently feel like text is popping into place as streamed tokens mutate the bubble. That is efficient, but visually noisy. The desired feel is calmer: text should appear as visible lines, each line fading in and settling gently, like the reply is surfacing rather than being typed token by token.

Alex selected the visual-line direction over token pop, soft reveal, and sentence-level reveal. The calibrated speed target is the slower "C" version:

- Line stagger: `450ms`
- Loop/mock timing reference: `7.2s` for five preview lines
- Motion: `opacity 0 -> 1` plus `translateY(10px -> 0)`
- Curve reference: `cubic-bezier(.17, .76, .18, 1)`
- No blur

## Goals

- During an active assistant stream, prose appears one visible line at a time with the calibrated fade/settle motion.
- The LLM still streams normally. The UI must not buffer model output in a way that makes the assistant feel slower to answer.
- Once a reply is complete and persisted, it renders as normal static Markdown, preserving selection, copy, layout, and existing message behavior.
- The first slice applies to assistant prose text only. Tables and code/verbatim blocks remain stable.
- The implementation follows existing chat rendering boundaries instead of adding a new message pipeline.

## Non-goals

- No sentence-based reveal. The user corrected the target: the animation should follow visible lines, not sentence boundaries.
- No token pacing changes in `ChatViewModel`.
- No multi-bubble reply split.
- No third-party animation or text-layout dependency.
- No changes to `anchor.md`.
- No animation for user messages.

## Design

### 1. Keep Streaming Data Flow Unchanged

`ChatViewModel` continues appending text deltas into `currentResponse`. The generation path remains:

`LLM stream -> currentResponse.append(delta) -> ChatArea renders draft bubble`

The fade is a presentation detail inside the assistant bubble. This keeps latency honest: Nous can still show that a reply has started as soon as the first useful text arrives.

### 2. Add A Streaming-Only Assistant Text Path

`MessageBubble` already knows when it is rendering the active draft because the streaming draft path passes streaming flags, while persisted messages pass non-streaming flags. The implementation should make that explicit with a small parameter or local condition such as `isStreamingDraft`.

For non-streaming assistant messages:

`AssistantBubbleContent -> ChatMarkdownRenderer.parse(displayText) -> ChatMarkdownView`

For streaming assistant prose:

`AssistantBubbleContent -> ChatMarkdownRenderer.parse(displayText) -> streaming-aware prose renderer`

Only `.prose` segments use the visual-line fade in v1. Other segments render through the existing `segmentView` behavior.

### 3. Measure Actual Visual Lines

The animation must follow actual visual lines, not punctuation or hard-coded string chunks. Because line wrapping depends on bubble width, font, and current text, the renderer needs a small layout helper that can split a prose string into line ranges for a given width.

Recommended helper:

`VisualLineBreaks.lines(for text: String, width: CGFloat, font: NSFont) -> [String]`

Implementation can use AppKit text layout (`NSTextStorage`, `NSLayoutManager`, `NSTextContainer`) with the same body font and line wrapping width used by chat prose. That keeps the behavior native and avoids third-party dependencies.

The helper should be deliberately narrow:

- Input: plain prose string, width, font
- Output: line strings in display order
- No Markdown parsing
- No persistence
- No knowledge of chat state

### 4. Render Lines With Stable Identity

Each measured line renders as its own `Text` row inside a leading `VStack`. New lines fade in with the calibrated motion:

- Stagger: `0.45s` per newly appearing line
- Opacity: `0 -> 1`
- Offset: `y: 10 -> 0`
- Curve: SwiftUI timing curve approximating `.17, .76, .18, 1`

To avoid replaying the entire answer on every token, line identity should be based on the line index plus a stable prefix/hash of the line content. Existing lines stay visible; only newly added lines animate.

If a resize changes wrapping, the renderer can reset line identities and re-layout without trying to preserve every animation. Window resize during an active stream is not the core path.

### 5. Completion Falls Back To Static Markdown

When the stream completes, `ChatViewModel` moves the assistant content from `currentResponse` into `messages` and clears the streaming state. The final persisted bubble then renders through the existing static `ChatMarkdownView`.

That is important because the streaming view may split prose into multiple `Text` rows for animation, but the final answer should behave like the normal Markdown bubble for text selection and future layout.

### 6. Markdown Boundaries

v1 handles:

- `.prose`: visual-line fade while streaming
- `.heading`: existing static heading rendering
- `.bulletBlock`: existing static bullet rendering
- `.table`: existing static table rendering
- `.horizontalRule`: existing static divider
- `.verbatim`: existing static verbatim rendering

After prose feels right in real use, bullets can be considered for the same visual-line treatment. That should be a follow-up, not bundled into v1.

## Testing

- Unit-test the line splitting helper with deterministic prose, fixed width, and the chat body font. Assert it produces multiple ordered lines and preserves full text when joined.
- Unit-test the streaming renderer policy if extracted: streaming prose routes to visual-line rendering; non-streaming prose routes to normal static Markdown.
- Existing `ChatMarkdownRenderer` tests should continue to pass unchanged.
- Manual verification in the running app: send a normal chat prompt that streams a paragraph, confirm lines fade with the C timing and the final message becomes static after completion.

## Risks

- AppKit line measurement may not perfectly match SwiftUI `Text` wrapping. Keep the helper scoped and tune with the exact font/width used by the assistant bubble.
- Re-wrapping during window resize can replay animations. Accept for v1; avoid over-engineering resize persistence.
- Per-line `Text` rows can reduce text-selection quality while streaming. Accept because the final persisted bubble returns to static Markdown.
- Applying the effect to tables/code would create visual instability. Keep them static.

## Acceptance Criteria

- Active assistant prose streams with visual-line fade using the C timing: `450ms` stagger, no blur, gentle y-settle.
- Model output starts showing immediately; no sentence/full-line buffering in the data pipeline.
- Completed messages render through normal static Markdown.
- Tables, code/verbatim blocks, headings, and user bubbles are not visually disrupted.
- Focused tests and a macOS build pass.
