# Clarification Trigger Redesign

## Overview

Nous's current clarification behavior asks whenever context feels insufficient. The default LLM bias is to gather facts ("讲多啲？" / "点解？") before committing to interpretation. In a mentor context, this reads as cold interrogation and fails to serve Alex: most of what Alex already said carries enough signal for a load-bearing response, and when it doesn't, the question worth asking is almost never a surface fact-gathering one.

Redesign the trigger so Nous only asks when the question carries a genuine hypothesis—i.e., when Nous has formed a candidate interpretation of what's underneath what Alex said, and when Alex confirming or rejecting that interpretation would materially change Nous's next response.

When multiple plausible hypotheses exist (≤2, closest ones only), surface them as a structured `<card>` that the app renders as a single inline UI card with tap-able options. When no hypothesis is worth surfacing, Nous has three fallback channels: direct response, inline observation, or defer (no output).

Target model: Gemini 2.5 Pro (upgraded from 2.5 Flash to support more reliable meta-reasoning on the depth test).

## Problem

Current anchor (`Sources/Nous/Resources/anchor.md`) Core Principle #1:

> 理解先于判断。问清楚先，再讲你点睇。唔好喺无足够上下文嘅时候出答案。

Current `做决定` example:

> Alex: "我想 quit school 专心 build"
> Nous: "咩令你有呢个念头？系觉得 school 嘥时间，定系有其他原因？"

Two failure modes this produces:

1. **Surface filler questions**: "咩事呀？" / "讲多啲？" / "点解？" — gather facts but don't commit to an interpretation. Feel interrogative. Alex's answer rarely pivots Nous's actual next response.
2. **Weak binary forks**: "系 A 定 B？" — offers fork but both branches are still surface. Nous hasn't guessed at what Alex is actually avoiding.

Real mentorship requires the opposite: the mentor forms a hypothesis about what the speaker might not be seeing, and names it. Either as a direct observation, or—when genuinely torn between 2 likely readings—by surfacing both and letting the speaker pick.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Trigger criterion | Depth test as single-sentence rule | "Would Alex's yes/no change my next response?" is testable; multi-step meta-reasoning drifts |
| Max hypotheses per card | 2, closest only | 5+ feels like interrogation; beyond 2 usually means Nous is overthinking |
| Card vs inline | ≥2 hypotheses → card; 1 → inline | Card is a UI affordance for genuine forks; single hypothesis doesn't need the structure |
| Fallback when test fails | 3 explicit channels (a/b/c) | Without fallback spec, model freezes or reverts to filler |
| Defer mechanism | `<defer/>` tag, zero output | Real mentorship includes strategic silence; chat UI must handle it explicitly |
| Output format | XML-like tags (`<card>`, `<defer/>`) | More robust than JSON for LLM output; parse failures degrade gracefully |
| Model | Gemini 2.5 Pro | Pro handles the nuanced meta-rule more reliably than Flash |
| "Escape" option | UI-fixed "写下你的想法" | Always present on every card; not LLM-generated |

## Prompt Architecture Changes

### Change 1: Rewrite Core Principle #1

**Before**:
```
1. 理解先于判断。问清楚先，再讲你点睇。唔好喺无足够上下文嘅时候出答案。
```

**After**:
```
1. 理解先于判断。但「问清楚」唔等如问 filler——冇 hypothesis 嘅问题唔值得出。
   宁愿直接回应佢讲嘅嘢，或者静一静等佢继续，都唔好问无重量嘅问题。
```

### Change 2: Add `# CLARIFICATION RULE` section

Placement: between `# RESPONSE MODES` and `# CORE PRINCIPLES`.

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
    输出方法：`<defer/>` tag。

呢三个 fallback 全部都 forbid 问号结尾。问号只留畀通过 depth test 嘅卡。

当 depth test 通过，有 hypothesis：
- ≥2 个真・唔同嘅 hypothesis（最多 2 个，而且系最接近嘅）→ 出 <card>
- 1 个 hypothesis → inline 讲（可以问句、可以断言，但要带分量）
- 5 个或以上 → 你谂多咗。Fall back 去 (a)。

注意：当 `# EMOTION DETECTION` 触发（Alex 讲紧情绪），嗰条 hard rule 行先。
先回应情绪（1-2 句），然后先轮到 CLARIFICATION RULE。情绪阶段嘅
「咩事？」「同我讲讲」唔当作 filler——佢哋系陪伴嘅一部分，唔係 interrogation。
```

### Change 3: Add `# OUTPUT FORMAT` section

Placement: just after `# CLARIFICATION RULE`.

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
- `<option>` 数量：1 或 2（app 会硬加「写下你的想法」，你唔使 output）
- Option 文字：短、直接，一句完。唔用问号，用断言语气。
- Framing：一句 open door 嘅短句，例：「你问我呢个背后...」
- `<card>` block 之外唔好加其他 plain text。

## <defer/> —— 决定唔出声时

单独一个 tag，冇其他内容：

    <defer/>

App 收到 `<defer/>` 唔会 render message，保持 composer active，等 Alex 继续。
```

### Change 4: Rewrite affected examples

Existing `# EXAMPLES` has content that violates the new rule. Targeted rewrites:

**做决定 → 「我想 quit school 专心 build」**

Before:
```
Alex: "我想quit school专心build"
Nous: "咩令你有呢个念头？系觉得 school 嘥时间，定系有其他原因？"
```

After:
```
Alex: "我想quit school专心build"
Nous: <card>
      <framing>你嘅 F-1 系靠 school。你问我呢个背后...</framing>
      <option>已经决定咗，想我 confirm</option>
      <option>Build 卡咗，想用 quit 推自己 commit</option>
      </card>
```

**情绪支持 → 「我 roommate 每晚都好嘈，已经两个月，好崩溃」**

Before:
```
Alex: "我roommate每晚都好嘈，已经两个月，好崩溃"
Nous: "两个月，真系难顶。你有冇同佢讲过？"
```

After (fallback b, inline observation):
```
Alex: "我roommate每晚都好嘈，已经两个月，好崩溃"
Nous: "两个月。忍到今日先讲，应该系顶到临界。"
```

**日常倾偈 → 「返到屋企了」**

Before:
```
Alex: "返到屋企了"
Nous: "辛苦晒。今日点？"
```

After (fallback a, direct response—"今日点？" was filler):
```
Alex: "返到屋企了"
Nous: "辛苦晒。"
```

Other existing examples should be audited against the rule during implementation. A non-exhaustive pass:
- `「我想 buy MacBook」` → current "而家部机有咩问题？" is filler; rewrite as direct response or card
- `「hi」` / `「咩叫 first principles thinking」` → likely fine (knowledge/greeting modes unaffected)

## App Layer Changes

Changes required beyond prompt/model config:

### `Sources/Nous/Services/LLMService.swift`

One-line change at line 154:

```swift
// Before
var model: String = "gemini-2.5-flash"

// After
var model: String = "gemini-2.5-pro"
```

### `Sources/Nous/Models/Message.swift`

Extend `Message` struct with optional card payload:

```swift
struct CardPayload: Codable, Equatable {
    let framing: String
    let options: [String]
}

struct Message: Identifiable, Codable {
    // ...existing fields...
    let cardPayload: CardPayload?
    // ...
}
```

Backwards compat: existing rows with `cardPayload == nil` behave as before (plain text message).

### `Sources/Nous/ViewModels/ChatViewModel.swift`

Add tag-parsing step after LLM response received, before appending to thread:

1. If response trimmed equals `<defer/>` (ignoring surrounding whitespace) → do not append message; keep composer active; log for debugging. If `<defer/>` appears alongside other text, treat as malformed: strip the tag, render the remaining text.
2. If response contains `<card>...</card>` → parse out `<framing>` and `<option>` elements into `CardPayload`; append message with `cardPayload` populated and `content` set to the framing.
3. Otherwise → strip any stray tags and append as normal plain-text message.

Tag parsing should be defensive: malformed tags fall back to plain-text rendering with raw content preserved. No crash on parse failure.

### `Sources/Nous/Views/ChatArea.swift`

In message list rendering, branch on `message.cardPayload`:
- `nil` → existing plain-text message bubble
- non-nil → new `CardView` component

### New: `Sources/Nous/Views/CardView.swift`

SwiftUI component matching the sketch:
- Rounded container bubble
- Framing text at top
- Vertical stack of option bubbles (each tap-able)
- Bottom row: fixed "写下你的想法" option (UI-provided, not LLM-provided)

Interaction:
- Tap option bubble → submit option text as Alex's next user message, triggering next LLM turn
- Tap "写下你的想法" → focus the ChatComposer text field, no auto-submit

Visual treatment follows existing chat bubble style; details deferred to implementation.

### `Sources/Nous/Views/ChatComposer.swift`

Expose a way to receive focus programmatically (for the "写下你的想法" tap handler).

## Testing / Validation

Prompt-level behavior is LLM-dependent and cannot be unit-tested deterministically. Validation strategy:

1. **Manual scenario pass**: Run the 8 canonical scenarios from `# EXAMPLES` through the new anchor + Pro model, verify responses match new expectations (card when appropriate, inline when appropriate, no filler questions).
2. **Depth test audit**: For any Nous response containing a question mark, manually check whether the depth test passes. Target: 0 filler questions across 20 varied test prompts.
3. **Defer observation**: Verify `<defer/>` appears in ambient scenarios (e.g., short greetings mid-conversation) without breaking UX.
4. **Card render**: Manual smoke test — confirm 2-option card renders correctly, tap flow submits text, "写下你的想法" focuses composer.

Regressions to watch:
- Response too short / cold (over-correction from filler-removal)
- Card appears too often (should be rare, only on real forks)
- `<defer/>` used as a crutch to avoid hard cases

## Scope / Non-Goals

In scope:
- Anchor.md changes per sections above
- Model swap to Gemini 2.5 Pro
- `Message.cardPayload` extension and tag parsing in ChatViewModel
- `CardView` component and integration in ChatArea
- `<defer/>` handling

Out of scope:
- Streaming-aware tag parsing (this codebase currently assembles full response before rendering—if that changes, tag parsing must be revisited)
- Persisting card interactions beyond normal message history
- A/B testing infrastructure for comparing old vs new behavior
- Localization of "写下你的想法" (stays Cantonese, matching Nous's voice)
- Multi-turn card chains (one card at a time; if Alex taps and Nous needs to ask again, new turn, new decision)
