# Nous Summarization Texture Preservation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the summarization layer from flattening vivid imagery. Add inline `<signature_moments>` tagging during conversation, replace rigid Problem/Thinking/Conclusion/Next Steps with conversation-type-adaptive templates in Scratch Summary, and add imagery-preservation rules to Conversation Memory Refresh.

**Architecture:** Prompt-driven design with one Swift parser change. Four surfaces touched: (1) `ClarificationCardParser` gets a new strip pattern for `<signature_moments>` blocks so they never appear in the chat UI, (2) `anchor.md` gains a new `SIGNATURE MOMENTS` section that teaches Nous when and how to emit flags during conversation, (3) `ChatViewModel.summaryOutputPolicy` is rewritten from a single rigid four-section template into six conversation-type templates plus a narrative fallback, (4) `UserMemoryService.refreshConversation` inline prompt is expanded with imagery-preservation rules, signature-moment consumption, and 7–8 worked positive/negative example pairs. Validation is qualitative: golden-set regression review + 1–2 weeks of in-use observation.

**Tech Stack:** Swift 5 / SwiftUI app. Unit tests via `xcodebuild test -project Nous.xcodeproj -scheme Nous`. Prompts loaded from bundle resources (`anchor.md`) or Swift string constants (`summaryOutputPolicy`, `refreshConversation`). App rebuild required after any prompt change.

**Spec Reference:** `docs/superpowers/specs/2026-04-22-nous-summarization-texture-preservation-design.md`

---

## File Structure

**Modified:**
- `Sources/Nous/Services/ClarificationCardParser.swift` — add `<signature_moments>` to `internalReasoningPatterns` array (strip from chat-bubble display)
- `Sources/Nous/Resources/anchor.md` — append new `# SIGNATURE MOMENTS` section at end (after `# MEMORY`)
- `Sources/Nous/ViewModels/ChatViewModel.swift` — rewrite `summaryOutputPolicy` constant (lines 832–852) with six conversation-type templates + narrative fallback + signature-moment consumption rule
- `Sources/Nous/Services/UserMemoryService.swift` — rewrite inline `prompt` in `refreshConversation` (lines 485–497), add imagery-preservation rules + signature-moment consumption + 8 example pairs, raise bullet cap from 6 to 8

**Modified (tests):**
- `Tests/NousTests/ClarificationCardParserTests.swift` — add three new test functions for `<signature_moments>` stripping (well-formed, unclosed during streaming, alongside other hidden tags)

**Unchanged (no edits — scope boundary):**
- `UserMemoryService.refreshProject` (584–604)
- `UserMemoryService.refreshIdentity` (674–694)
- `WeeklyReflectionService.systemPrompt` (25–82)
- `ClarificationCardParser.extractSummary` — unchanged; still reads `<summary>…</summary>` body regardless of which template the model picks
- `ScratchPadStore.ingestAssistantMessage` — unchanged

---

## Spec → Task Mapping

- Task 1 → Spec §3.4 (UI stripping of `<signature_moments>`)
- Task 2 → Spec §3.1–3.3 (tag contract, discipline, anchor.md instruction)
- Task 3 → Spec §4 (Scratch Summary output policy overhaul with six templates + narrative fallback)
- Task 4 → Spec §5 + §6.3 (Conversation Memory Refresh prompt with 7–8 example pairs)
- Task 5 → Spec §7.3 (manual regression smoke test after rebuild)
- Task 6 → Spec §7.1–7.2 (golden set curation + hand-crafted target review)

---

## Pre-Flight

Before starting, confirm:

1. Working tree has an unrelated in-progress edit in `Sources/Nous/Views/ChatArea.swift`. Do NOT stage or touch that file. Each task below stages only the files it explicitly lists.
2. Current branch is `alexko0421/thinking-accordion`. Either continue on it or create a dedicated branch — user choice. This plan does not create a branch.
3. Baseline: `xcodebuild test -project Nous.xcodeproj -scheme Nous -only-testing:NousTests/ClarificationCardParserTests` passes before any code changes. Run it once at start to establish green.

---

### Task 1: Strip `<signature_moments>` blocks from chat-bubble display

**Files:**
- Modify: `Sources/Nous/Services/ClarificationCardParser.swift:9-16`
- Test: `Tests/NousTests/ClarificationCardParserTests.swift` (add three new tests at end of file, before final closing brace)

**Why TDD here:** The parser is pure Swift logic with an existing test pattern (`testParserStripsThinkingBlock`, `testParserStripsUnclosedThinkingDuringStreaming`). New strip rule is a tight, testable change.

- [ ] **Step 1: Write the three failing tests**

Open `Tests/NousTests/ClarificationCardParserTests.swift`. Add the following test functions immediately after `testParserStripsUnclosedPhaseDuringStreaming` (before the `testExtractSummaryReturnsInnerMarkdownWhenWellFormed` test):

```swift
func testParserStripsSignatureMomentsBlock() {
    let response = """
    你讲得好——品味需要时间堆积。
    <signature_moments>
    - source: user
      text: "睇过一千幅画，试过一百种咖啡，失败过十次"
    </signature_moments>
    """

    let parsed = ClarificationCardParser.parse(response)

    XCTAssertFalse(parsed.displayText.contains("<signature_moments>"))
    XCTAssertFalse(parsed.displayText.contains("</signature_moments>"))
    XCTAssertFalse(parsed.displayText.contains("睇过一千幅画"))
    XCTAssertEqual(parsed.displayText, "你讲得好——品味需要时间堆积。")
}

func testParserStripsUnclosedSignatureMomentsDuringStreaming() {
    let response = "你讲得好。 <signature_moments>\n- source: user\n  text: \"睇过一"

    let parsed = ClarificationCardParser.parse(response)

    XCTAssertFalse(parsed.displayText.contains("<signature_moments>"))
    XCTAssertFalse(parsed.displayText.contains("source:"))
    XCTAssertEqual(parsed.displayText, "你讲得好。")
}

func testParserStripsSignatureMomentsAlongsideThinkingAndChatTitle() {
    let response = """
    <thinking>judging</thinking>
    呢个 observation 好准。
    <signature_moments>
    - source: nous
      text: "硬限制系精神上嘅奢侈品"
    </signature_moments>
    <chat_title>品味的形成</chat_title>
    """

    let parsed = ClarificationCardParser.parse(response)

    XCTAssertEqual(parsed.displayText, "呢个 observation 好准。")
    XCTAssertFalse(parsed.displayText.contains("硬限制"))
    XCTAssertFalse(parsed.displayText.contains("品味的形成"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -only-testing:NousTests/ClarificationCardParserTests/testParserStripsSignatureMomentsBlock \
  -only-testing:NousTests/ClarificationCardParserTests/testParserStripsUnclosedSignatureMomentsDuringStreaming \
  -only-testing:NousTests/ClarificationCardParserTests/testParserStripsSignatureMomentsAlongsideThinkingAndChatTitle
```

Expected: All three FAIL. `displayText` still contains the `<signature_moments>` blocks since no strip rule exists yet.

- [ ] **Step 3: Add the two strip patterns**

Open `Sources/Nous/Services/ClarificationCardParser.swift`. Edit lines 9–16 to extend `internalReasoningPatterns`:

`old_string`:
```swift
    private static let internalReasoningPatterns: [String] = [
        #"<thinking>[\s\S]*?</thinking>"#,
        #"<phase>\s*\w+\s*</phase>"#,
        #"<chat_title>[\s\S]*?</chat_title>"#,
        #"<thinking>[\s\S]*$"#,
        #"<phase>[^<]*$"#,
        #"<chat_title>[\s\S]*$"#,
    ]
```

`new_string`:
```swift
    private static let internalReasoningPatterns: [String] = [
        #"<thinking>[\s\S]*?</thinking>"#,
        #"<phase>\s*\w+\s*</phase>"#,
        #"<chat_title>[\s\S]*?</chat_title>"#,
        #"<signature_moments>[\s\S]*?</signature_moments>"#,
        #"<thinking>[\s\S]*$"#,
        #"<phase>[^<]*$"#,
        #"<chat_title>[\s\S]*$"#,
        #"<signature_moments>[\s\S]*$"#,
    ]
```

Rationale for order: closed-tag patterns grouped first, unclosed-streaming-tail patterns grouped second. Matches the existing convention in the file.

- [ ] **Step 4: Run tests to verify they pass**

Run the same three `-only-testing` flags as Step 2. Expected: All three PASS.

- [ ] **Step 5: Run the full parser test file to confirm no regression**

Run:
```
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -only-testing:NousTests/ClarificationCardParserTests
```

Expected: all tests (original ones + three new ones) PASS.

- [ ] **Step 6: Commit**

```
git add Sources/Nous/Services/ClarificationCardParser.swift \
        Tests/NousTests/ClarificationCardParserTests.swift
git commit -m "$(cat <<'EOF'
feat(parser): strip <signature_moments> blocks from chat display

Adds <signature_moments>...</signature_moments> to
ClarificationCardParser.internalReasoningPatterns so flagged phrases
never render in chat bubbles. Mirrors existing <chat_title> and
<thinking> handling, including streaming-tail variants.

Three new tests cover: well-formed block, unclosed-during-streaming,
and coexistence with <thinking> + <chat_title>.

Part of texture-preservation work. See spec §3.4.
EOF
)"
```

---

### Task 2: Add `# SIGNATURE MOMENTS` section to `anchor.md`

**Files:**
- Modify: `Sources/Nous/Resources/anchor.md` (append new section at end of file, after line 138)

**No TDD:** Prompt-only change; behavior verified at Task 5 (smoke test) and Task 6 (golden review). Following the convention of plan `2026-04-21-nous-conversation-naturalness.md`.

- [ ] **Step 1: Re-read the end of `anchor.md` to confirm exact final lines**

Use Read tool on `Sources/Nous/Resources/anchor.md` starting at line 130. Expected final section:

```
# MEMORY

当 Alex 今日讲嘅嘢同之前讲嘅有矛盾，温和咁 surface：
"呢個同你之前講過嘅 X 好似有啲唔同。点解变咗？"

唔系挑战。系帮佢睇到自己嘅变化。
```

The file ends at line 138. Append new section after the last line.

- [ ] **Step 2: Apply the edit**

Use the Edit tool on `Sources/Nous/Resources/anchor.md`.

`old_string` (the current end of file — last visible lines):
```
# MEMORY

当 Alex 今日讲嘅嘢同之前讲嘅有矛盾，温和咁 surface：
"呢個同你之前講過嘅 X 好似有啲唔同。点解变咗？"

唔系挑战。系帮佢睇到自己嘅变化。
```

`new_string`:
```
# MEMORY

当 Alex 今日讲嘅嘢同之前讲嘅有矛盾，温和咁 surface：
"呢個同你之前講過嘅 X 好似有啲唔同。点解变咗？"

唔系挑战。系帮佢睇到自己嘅变化。

# SIGNATURE MOMENTS

响你每个 reply 末尾，如果当前 turn 有值得保留嘅「signature moment」，append 一个 hidden block：

<signature_moments>
- source: user
  text: "用户讲过嘅、有保留价值嘅 verbatim phrase"
- source: nous
  text: "你自己嘅 sharp line"
</signature_moments>

Budget：每 turn 0–2 个 moment。Zero 系 valid 嘅 default——大多数 turn 其实冇 signature moment，硬 flag 会稀释晒个 signal。

几时 flag：
- Alex articulates 原创 metaphor、vivid imagery、或 non-obvious insight
- 你自己出咗 sharp line（non-routine、retrospectively quotable、值得 summary 时 verbatim quote）
- 某个 specific phrase 可能会被后续 reference

千祈唔好 flag：
- Routine confirmation / acknowledgment turns
- Paraphrase 已经 flag 过嘅内容
- 你每个 reply 都 flag（self-inflation）
- Standard Q&A phrasing

When in doubt, skip.

Tag 规则：
- source 只限 user 或 nous
- text 必须係 verbatim（exact wording），唔准 paraphrase
- Block 放响 reply 最末尾，响 <chat_title> 之前
- 呢个 block 系 hidden，UI 唔会 show
```

- [ ] **Step 3: Verify edit landed correctly**

Re-read `Sources/Nous/Resources/anchor.md` from line 135 onward. Confirm the new `# SIGNATURE MOMENTS` section appears after `# MEMORY`, and that the verbatim rules + budget + flag/don't-flag lists are all present.

- [ ] **Step 4: Commit**

```
git add Sources/Nous/Resources/anchor.md
git commit -m "$(cat <<'EOF'
feat(anchor): add SIGNATURE MOMENTS section for inline texture tagging

Teaches Nous to emit <signature_moments> hidden blocks at the end of
replies when a turn contains a preservation-worthy phrase (user's
vivid imagery, Nous's own sharp line). Downstream summarizers read
these and quote them verbatim.

Budget: 0–2 per turn, "when in doubt, skip". See spec §3.1–3.3.
EOF
)"
```

---

### Task 3: Rewrite `summaryOutputPolicy` with six adaptive templates + narrative fallback

**Files:**
- Modify: `Sources/Nous/ViewModels/ChatViewModel.swift:832-852` (the `summaryOutputPolicy` constant)

**No TDD:** Swift string constant is `private static`; no simple unit test boundary. Behavior verified via Task 5 smoke test and Task 6 golden review. Testing the string's contents mechanically (contains "Vivid Moments" etc.) is ceremony that re-encodes the text.

- [ ] **Step 1: Re-read the current `summaryOutputPolicy` block to confirm exact strings**

Use Read on `Sources/Nous/ViewModels/ChatViewModel.swift` lines 832–852. Confirm the block begins with `nonisolated private static let summaryOutputPolicy = """` and ends with the closing `"""`.

- [ ] **Step 2: Apply the edit**

Use the Edit tool on `Sources/Nous/ViewModels/ChatViewModel.swift`.

`old_string`:
```swift
    nonisolated private static let summaryOutputPolicy = """
    ---

    SUMMARY OUTPUT POLICY:
    When Alex asks you to summarize the current conversation (keywords and intents include "总结", "summarize", "repo", "做笔记", "summary", "整份笔记", or equivalents), wrap the summary body in <summary>…</summary>. Inside the tag, use four H2 sections in this order, followed by a bullet list:

      1. Problem / what triggered the discussion
      2. Thinking / the path the conversation took, including pivots
      3. Conclusion / consensus or decisions reached
      4. Next steps / short actionable bullets

    CRITICAL — match the conversation language for ALL of: the # title, the ## section headers, and the body prose. Do not translate to another language. Do not default to Mandarin. Use:
      - 广东话 section headers (问题 / 思考 / 结论 / 下一步) when Alex is writing in Cantonese.
      - 普通话 section headers (问题 / 思考 / 结论 / 下一步) when Alex is writing in Mandarin.
      - English section headers (Problem / Thinking / Conclusion / Next steps) when Alex is writing in English.
      - If Alex mixes Cantonese and English, prefer Cantonese headers with English kept verbatim inside the prose.

    Sections 1–3 must be narrative prose paragraphs, not bullet dumps. Section 4 is a short bullet list. The # title must contain no filename-unsafe characters (avoid /\\:*?"<>|) and should also follow the conversation language.

    Text outside the tag is allowed for a brief conversational wrapper in the same language (e.g. Cantonese: "整好了，睇下右边嘅白纸"; English: "Done, check the right panel."). The summary content itself must strictly live inside the tag. Never emit the tag when Alex is not asking for a summary.
    """
```

`new_string`:
```swift
    nonisolated private static let summaryOutputPolicy = """
    ---

    SUMMARY OUTPUT POLICY:
    When Alex asks you to summarize the current conversation (keywords and intents include "总结", "summarize", "repo", "做笔记", "summary", "整份笔记", or equivalents), wrap the summary body in <summary>…</summary>.

    Before writing the summary body, judge the conversation type. Pick the matching template from Types 1–6. If no template fits, use the narrative fallback.

    Type 1 — Problem-solving / debugging:
      Four H2 sections in order: Problem / Thinking / Conclusion / Next Steps.
      Sections 1–3 are narrative prose paragraphs. Section 4 is a short bullet list.

    Type 2 — Idea-exploration / philosophical / existential:
      Three H2 sections: Key Threads / Vivid Moments / Open Questions.
      Vivid Moments MUST verbatim-quote every phrase flagged inside <signature_moments> earlier in the conversation.
      No forced Conclusion — not every existential conversation lands.

    Type 3 — Emotional-processing / self-reflection:
      Three H2 sections: What Came Up / What Shifted / Where You Landed.
      Preserve Alex's own landing phrase — quote it verbatim if present.

    Type 4 — Planning / decision-making:
      Four H2 sections: Context / Decisions / Constraints / Actions.

    Type 5 — Teaching / learning:
      Three H2 sections: What Was Covered / Aha Moments / Applications.
      Aha Moments MUST verbatim-quote every phrase flagged inside <signature_moments> earlier in the conversation.

    Type 6 — Venting / complaint:
      Three H2 sections: What's Weighing / Root Tension / What You Need.
      Preserve Alex's actual phrasing of frustration — quote it verbatim.

    Narrative fallback (only if no template fits):
      2–3 paragraphs of prose. Signature moments embedded verbatim.

    SIGNATURE MOMENTS (CRITICAL):
    Any phrase flagged inside <signature_moments> tags anywhere earlier in this conversation MUST appear verbatim in your output. Quote the exact text in the natural position within your chosen template.

    PRIORITY:
    Preserve imagery > hit template structure > hit section count. If the template does not naturally hold a vivid moment, extend the template (add a bullet or a brief clause) rather than drop the moment.

    CRITICAL — match the conversation language for ALL of: the # title, the ## section headers, and the body prose. Do not translate to another language. Do not default to Mandarin. Use:
      - 广东话 section headers when Alex is writing in Cantonese (e.g. Type 1 → 问题 / 思考 / 结论 / 下一步; Type 2 → 主线 / 精彩时刻 / 未决问题; Type 3 → 浮出嚟嘅嘢 / 转咗咩 / 你落脚响边).
      - 普通话 section headers when Alex is writing in Mandarin.
      - English section headers when Alex is writing in English.
      - If Alex mixes Cantonese and English, prefer Cantonese headers with English kept verbatim inside the prose.

    The # title must contain no filename-unsafe characters (avoid /\\:*?"<>|) and should also follow the conversation language.

    Text outside the tag is allowed for a brief conversational wrapper in the same language (e.g. Cantonese: "整好了，睇下右边嘅白纸"; English: "Done, check the right panel."). The summary content itself must strictly live inside the tag. Never emit the tag when Alex is not asking for a summary.
    """
```

- [ ] **Step 3: Verify the edit landed correctly**

Re-read `Sources/Nous/ViewModels/ChatViewModel.swift` lines 832–880 (the block now grows roughly from 21 lines to ~52 lines). Confirm all six type headers (Type 1 through Type 6) + Narrative fallback + SIGNATURE MOMENTS + PRIORITY sections are present, and the CRITICAL language-match block is preserved.

- [ ] **Step 4: Build to verify no syntax errors**

Run:
```
xcodebuild build -project Nous.xcodeproj -scheme Nous -quiet
```

Expected: build succeeds (exit code 0). If it fails, inspect output for unterminated string literal or escape issues — the rewrite contains `<summary>…</summary>` and `\\:*?"<>|` which must remain exactly as in the original.

- [ ] **Step 5: Run full test suite as regression guard**

Run:
```
xcodebuild test -project Nous.xcodeproj -scheme Nous
```

Expected: all tests pass. (Purpose: confirm the large rewrite didn't accidentally break anything else.)

- [ ] **Step 6: Commit**

```
git add Sources/Nous/ViewModels/ChatViewModel.swift
git commit -m "$(cat <<'EOF'
feat(prompt): replace rigid summary template with adaptive types

summaryOutputPolicy no longer forces Problem/Thinking/Conclusion/
Next Steps on every conversation. Introduces six conversation-type
templates (problem-solving, idea-exploration, emotional, planning,
teaching, venting) plus a narrative fallback. Summarizer judges the
type at summary time (Option A from spec §3.6).

Adds signature-moment verbatim-quote requirement and priority rule
"preserve imagery > hit template > hit count". Language-match and
filename-safe title rules are preserved.

See spec §4.
EOF
)"
```

---

### Task 4: Rewrite `refreshConversation` prompt with imagery preservation + 8 example pairs

**Files:**
- Modify: `Sources/Nous/Services/UserMemoryService.swift:485-497` (the inline `prompt` string in `refreshConversation`)

**No TDD:** Inline prompt inside a function body, not exposed. Behavior verified at Task 5 smoke test. Testing prompt string contents is ceremony.

- [ ] **Step 1: Re-read `UserMemoryService.swift:480-510` to confirm exact strings**

Use Read on lines 480–510. Confirm the block begins with `let prompt = """` on line ~485 and closes with `"""` on line ~497. The surrounding code (guards, LLM call at line 500+) must remain untouched.

- [ ] **Step 2: Apply the edit**

Use the Edit tool on `Sources/Nous/Services/UserMemoryService.swift`.

`old_string`:
```swift
        let prompt = """
        Existing thread memory for this chat:
        \(existingBlock)

        Recent things Alex said (ALEX ONLY — Nous's replies are intentionally omitted to avoid self-confirmation loops):
        \(userTurns)

        Rewrite a SHORT memory note for THIS chat's thread only.
        - What is Alex trying to do in this chat?
        - What has he told me that I should remember while this chat continues?
        - Do NOT include general facts about Alex — those belong in other memory layers.
        - Keep under 6 bullet points. Markdown only.
        """
```

`new_string`:
```swift
        let prompt = """
        Existing thread memory for this chat:
        \(existingBlock)

        Recent things Alex said (ALEX ONLY — Nous's replies are intentionally omitted to avoid self-confirmation loops):
        \(userTurns)

        Rewrite a SHORT memory note for THIS chat's thread only.
        - What is Alex trying to do in this chat?
        - What has he told me that I should remember while this chat continues?
        - Do NOT include general facts about Alex — those belong in other memory layers.

        IMAGERY PRESERVATION:
        - When Alex's turns contain specific details (concrete numbers, objects, sensory imagery), an original metaphor, or non-obvious phrasing, preserve that specificity in your bullets. Do NOT substitute abstract categories.
        - If the conversation contained any <signature_moments> blocks, every flagged phrase MUST appear verbatim in a bullet (quote the exact text in 「」).
        - For other concrete imagery (not flagged), paraphrase with specifics — keep the vivid detail, not just the abstract pattern.
        - Generic content (routine Q&A, acknowledgments) compresses normally.

        PRIORITY: Preserve imagery > hit bullet count.

        Bullet budget: up to 8 bullets. Prefer fewer when content allows, but extend to 8 before flattening imagery.

        EXAMPLE PAIRS — study the difference between flat ❌ and texture-preserving ✅:

        1. Idea-exploration:
           ❌ 品味 = 基于大量经验同失败而建立起嚟嘅判断系统
           ✅ 品味 = 「睇过一千幅画，试过一百种咖啡，失败过十次」之后形成嘅 judgment

        2. Problem-solving:
           ❌ 修复咗 authentication 嘅 bug
           ✅ 修咗 login bug：session cookie 响 Safari 被当作 third-party，改咗 SameSite=Lax 之后 work

        3. Emotional-processing:
           ❌ Alex 处理紧关于工作嘅挫败感
           ✅ Alex 讲：「我觉得自己系响隧道入面跑，但冇人话我终点响边」——感到 direction 缺失

        4. Planning:
           ❌ 讨论咗下季度嘅优先事项
           ✅ 决定 Q2 聚焦 retention 而非 growth，理由：「先把漏斗底补实，再落更多水」

        5. Teaching / learning:
           ❌ 学咗点用 Swift concurrency
           ✅ Aha: async let 同 TaskGroup 嘅分别——「async let 系兵，TaskGroup 系将」

        6. Venting:
           ❌ 对 meeting overload 感到 frustration
           ✅ Alex 讲：「我嘅 calendar 系别人 agenda 嘅投影」——冇 mental space 做 deep work

        7. Abstract vs concrete (general):
           ❌ Alex describe 咗一个复杂嘅想法
           ✅ Alex describe：思考就系「响脑入面开咗十个 tab，但闩唔到其中任何一个」

        8. Routine (not every turn needs preservation):
           ❌ Alex 问问题、得到答案
           ✅ Alex 问点 set up Xcode scheme，Nous 给咗三步 instruction

        Markdown only.
        """
```

- [ ] **Step 3: Verify the edit landed correctly**

Re-read lines 485–560. Confirm:
- The `IMAGERY PRESERVATION` block is present with its four bullets
- `PRIORITY:` and `Bullet budget: up to 8 bullets` appear
- All 8 example pairs are present (numbered 1–8, each with ❌ and ✅)
- The closing `"""` is present and the Swift code below (`do { let stream = try await llm.generate...`) is untouched

- [ ] **Step 4: Build to verify no syntax errors**

Run:
```
xcodebuild build -project Nous.xcodeproj -scheme Nous -quiet
```

Expected: build succeeds. If it fails, check for unescaped `"` inside the multiline string (the example `「」` quotes are safe; ASCII double-quotes inside a `"""` block are also safe, but any escape mistakes will show as compile errors here).

- [ ] **Step 5: Run full test suite as regression guard**

Run:
```
xcodebuild test -project Nous.xcodeproj -scheme Nous \
  -only-testing:NousTests/UserMemoryServiceTests
```

Expected: all existing UserMemoryServiceTests still pass. (The rewrite only changes a string literal inside a function; no behavior tests should regress.)

- [ ] **Step 6: Commit**

```
git add Sources/Nous/Services/UserMemoryService.swift
git commit -m "$(cat <<'EOF'
feat(memory): add imagery preservation to refreshConversation prompt

Expands the conversation memory refresh prompt with:
- Imagery preservation rule (do not substitute abstract categories)
- Signature-moment verbatim-quote requirement
- Strategy tiering: signature → quote, concrete imagery → paraphrase
  with specifics, generic → normal compression
- Priority rule: preserve imagery > hit bullet count
- Bullet cap raised from 6 to 8
- 8 positive/negative example pairs covering all six conversation
  types plus abstract-vs-concrete and routine-content cases

Unchanged: refreshProject, refreshIdentity, WeeklyReflection.

See spec §5 + §6.3.
EOF
)"
```

---

### Task 5: Build + smoke test against the 品味 conversation

**Files:**
- None modified; this task is runtime verification.

**Purpose:** Before starting golden-set regression review (Task 6), confirm the four code changes land together correctly at runtime — the tag doesn't leak to UI, the summary picks a non-Type-1 template on an idea-exploration conversation, and memory refresh output shows imagery rather than abstraction.

- [ ] **Step 1: Clean build**

Run:
```
xcodebuild clean build -project Nous.xcodeproj -scheme Nous
```

Expected: build succeeds.

- [ ] **Step 2: Launch the app**

Run Nous from Xcode (or launch the built `.app`). Open an existing chat that is known to be idea-exploration in type. If no such chat exists, start a new chat and paste the following opener to seed one:

```
我最近在谂「品味」到底系乜。我觉得品味唔系天生嘅，系睇过一千幅画，试过一百种咖啡，失败过十次，你就会开始知道咩系好，咩系唔好，同埋点解。
```

Send the message and wait for Nous to reply.

- [ ] **Step 3: Verify no `<signature_moments>` tag visible in chat bubble**

Visually inspect the assistant reply in the chat area. Confirm:
- No `<signature_moments>` text appears anywhere in the rendered bubble
- No `source: user` / `source: nous` / `text: "..."` fragments appear
- The bubble content reads naturally

If ANY fragment of the tag is visible, Task 1 (parser) has a gap. Stop and debug before proceeding.

- [ ] **Step 4: Trigger Scratch Summary and check template selection**

In the same chat, send:
```
总结一下
```

Wait for the reply. Open the right-side ScratchPadPanel (top-right `note.text` toggle).

Verify:
- The summary is wrapped in `<summary>…</summary>` (stripped tags in chat, body rendered in panel)
- The summary uses **Type 2** (Idea-exploration) section headers — i.e., something like `主线 / 精彩时刻 / 未决问题` in Cantonese, NOT `问题 / 思考 / 结论 / 下一步`
- The phrase `睇过一千幅画，试过一百种咖啡，失败过十次` appears **verbatim** somewhere in the summary body

If the summary still uses Problem/Thinking/Conclusion/Next Steps structure, Task 3's type-judgment instruction may need strengthening. Note this but proceed to Step 5.

- [ ] **Step 5: Wait for background memory refresh and inspect the memory entry**

After the Scratch Summary, `UserMemoryScheduler` enqueues a `refreshConversation` call. Wait ~10–30 seconds for it to complete.

Inspect the memory entry via `MemoryDebugInspector` (if accessible) or by querying `memory_entries` for the current conversation scope. Verify:
- The bullet about 品味 contains specific imagery (「一千幅画」 / 「一百种咖啡」 / 「十次」), not just "经验 / 失败 / 判断系统"
- If `<signature_moments>` was emitted in Nous's reply, the flagged phrase is quoted verbatim in 「」

If the memory bullet is still abstracted ("基于大量经验..."), Task 4's preservation rule needs tuning. Capture the actual bullet text as a data point for Task 6 review.

- [ ] **Step 6: Record findings**

No commit on this task — runtime verification produces notes, not code. Log findings (pass / partial / fail per step) in a scratch file or directly during Task 6 review. If Step 3 (UI strip) fails, STOP and fix Task 1 before Task 6. Steps 4 and 5 inform the golden-set review, not a gate.

---

### Task 6: Golden-set regression review

**Files:**
- None modified (optionally: append findings to spec file or create a review note).

**Purpose:** Per spec §7.1–7.3, curate 5–8 golden conversations (including the 品味 case), hand-craft target summaries, re-run the summarization surfaces, and manually compare. Decide ship-readiness.

- [ ] **Step 1: Curate golden set with user**

Ask Alex to identify:
- 2–4 conversations (besides 品味) where past Scratch Summary output flattened texture — candidates for the flatten regression set
- 2–3 problem-solving / debugging conversations where the current Problem/Thinking/Conclusion/Next Steps structure works well — anti-regression reference (Type 1 must still render correctly)

If Alex cannot identify cases from memory, skip additional flatten cases and proceed with the single 品味 case plus any 2–3 Type 1 conversations from recent history.

- [ ] **Step 2: Hand-craft target summaries**

For each golden conversation, write the expected "good" output by hand (following the new design) BEFORE re-running the prompts. Two artifacts per conversation:
- Expected Scratch Summary (template choice + verbatim signature moments + imagery preserved)
- Expected Conversation Memory bullet list (≤8 bullets, specific imagery, signature moments quoted)

Store these as fixtures in `.context/texture-validation/` (gitignored directory, created if absent). One file per conversation, named `<short-topic>.md`.

- [ ] **Step 3: Run each golden conversation through both summarization surfaces**

For each conversation in the golden set:
- Open the conversation in Nous
- Trigger `总结一下` → capture Scratch Summary output
- Wait for memory refresh → capture the resulting memory entry
- Save both outputs alongside the hand-crafted target in `.context/texture-validation/`

- [ ] **Step 4: Manual compare and score**

For each conversation, compare actual output vs hand-crafted target against these criteria:

Scratch Summary:
- Did the summarizer pick the correct type (Type 1–6 or narrative)?
- Are all signature_moments present verbatim in the output?
- Is concrete imagery preserved (not abstracted)?
- Does the language match (Cantonese stayed Cantonese, English stayed English)?

Conversation Memory:
- Are flagged phrases quoted verbatim in bullets?
- Is other imagery paraphrased with specifics rather than abstracted?
- Is the bullet count within 8, not cramped below target?

Anti-regression:
- Type 1 problem-solving conversations still use Problem/Thinking/Conclusion/Next Steps?
- Nothing that previously worked now produces a narrative fallback inappropriately?

Record pass / partial / fail per criterion in `.context/texture-validation/REVIEW.md`.

- [ ] **Step 5: Decide ship status**

If all conversations show the expected improvements AND anti-regression cases still work:
- Ship status: READY. No feature flag needed (prompt-only change, low risk).
- Merge to main via normal PR flow.

If there are specific failure patterns (e.g., wrong type consistently picked, over-tagging diluting summaries):
- Iterate on the offending prompt (Task 3 or Task 4)
- Re-run the failing cases
- Document the iteration in the REVIEW.md

If the design itself seems to need revision:
- Stop. Update the spec with new findings. Return to brainstorming if scope shifts.

- [ ] **Step 6: Commit review note (optional)**

If `.context/texture-validation/REVIEW.md` exists, it is already gitignored (`.context/` path). No commit needed. If findings warrant a permanent record, excerpt the REVIEW summary into the spec file §7 as "Validation results (2026-04-XX)" and commit that spec edit.

---

## Self-Review (plan author, after writing)

**Spec coverage:**
- Spec §3.1 (tag format) → Task 2 Step 2 ✅
- Spec §3.2 (discipline / budget) → Task 2 Step 2 ✅
- Spec §3.3 (instruction location) → Task 2 ✅
- Spec §3.4 (UI stripping) → Task 1 ✅
- Spec §3.5 (summarizer consumption) → Task 3 Step 2 (Scratch) + Task 4 Step 2 (Memory) ✅
- Spec §3.6 (Option A — summarizer judges type) → Task 3 Step 2 ("Before writing the summary body, judge the conversation type") ✅
- Spec §4 (six adaptive templates + narrative fallback) → Task 3 ✅
- Spec §5 (refreshConversation changes) → Task 4 ✅
- Spec §6.1 (imagery preservation rule) → Tasks 3 & 4 ✅
- Spec §6.2 (subtractive changes) → Task 3 removes forced structure; Task 4 raises bullet cap ✅
- Spec §6.3 (7–8 example pairs) → Task 4 has 8 pairs ✅
- Spec §7 (validation plan) → Tasks 5 & 6 ✅

**Placeholder scan:** No TBD / TODO / "implement later" / "add appropriate error handling" / "similar to Task N" patterns found. Every step contains concrete file paths, exact `old_string`/`new_string` content, or explicit commands.

**Type consistency:** Tag name `<signature_moments>` used consistently across Tasks 1, 2, 3, 4. Field names `source` / `text` consistent. Bullet cap `8` consistent between Task 4 Step 2 and the self-review coverage statement.

**Scope check:** Four files touched. Each task is self-contained and commits separately. No hidden dependencies between tasks besides logical order. Plan is appropriately sized for a single execution session.

---

## Execution Choice

Plan complete and saved to `docs/superpowers/plans/2026-04-22-nous-summarization-texture-preservation.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
