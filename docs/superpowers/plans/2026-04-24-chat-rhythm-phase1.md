# Chat Rhythm — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `RHYTHM` section and three new examples to `Sources/Nous/Resources/anchor.md` so Nous replies exhibit visible sentence-length variance and reactive beats, without regressing existing naturalness rules. Ship a structural regression test (`RhythmStyleGuardTests`) that fails if the new section, reconciliation clause, max-1-? rule, or reactive-beat disambiguation disappears.

**Architecture:** Prompt-layer only. Edit `anchor.md` and add one XCTest file. No Swift source code changes. The test reads `anchor.md` at runtime (resolved via `#file` path) and asserts structural invariants. No quality assertions — that is manual before/after corpus + real-session validation.

**Tech Stack:** Swift, XCTest, Xcode project (not SPM). `anchor.md` is a resource bundled into the main Nous target at `Sources/Nous/Resources/anchor.md`.

**Spec:** `docs/superpowers/specs/2026-04-24-chat-rhythm-design.md` §4 (Phase 1 only). §5 onward is Phase 2 and gated on Phase 1 real-session validation — **not in scope for this plan**.

**Out of scope:**
- Phase 2 (`RhythmJudge`, multi-bubble delivery, `ChatViewModel` turn refactor).
- Any change to `stoicGroundingPolicy` in `ChatViewModel.swift` or `ChatMode.contextBlock`. Spec §4.6 is explicit: those layers are not edited; RHYTHM reconciles alongside them.
- Committing the one-off corpus-validation harness (§4.4 step 4 — run once, don't commit).

---

## File Structure

Each file below has a single responsibility:

| File | Responsibility |
|------|----------------|
| `Sources/Nous/Resources/anchor.md` | Prompt. New `# RHYTHM` section after STYLE RULES; rewritten 倾观点 share-lead example; three new examples. |
| `Tests/NousTests/RhythmStyleGuardTests.swift` | Structural regression guard — four assertions from spec §4.5. Reads anchor.md from source tree via `#file`. |
| `Nous.xcodeproj/project.pbxproj` | Register the new test file in NousTests target (4 entry points; pattern mirrors `ProvocationJudgeTests.swift`). |

Files **not** touched:
- `Sources/Nous/ViewModels/ChatViewModel.swift` (stoicGroundingPolicy stays as-is per §4.6).
- `Sources/Nous/Models/ChatMode.swift` (companion/strategist blocks stay as-is per §4.6).

---

## Content drafts (reference for later tasks)

These are the candidate Cantonese texts Tasks 4, 6, 7, 8 apply to `anchor.md`. Drafted here so the tasks stay mechanical. **Alex's voice calibration is the final gate** — treat these drafts as "starting point for in-place tuning", not frozen text. If Alex revises them at apply-time, the test assertions (which only check structural anchors, not exact phrasing) still pass as long as the required anchor strings survive.

### Draft A — The new `# RHYTHM` section (goes after `# STYLE RULES`)

```
# RHYTHM

真人讲嘢有起伏。句长唔均匀。有时「嗯。」一句就 land，有时展开成一段。
Reply 内部嘅 sentence length variance 要 visible。

- 一个 reply 入面至少要有一句 ≤6 字（短 punch / 反应 beat），除非个 reply 本身全部都系极短 small talk（例如「辛苦晒。今日点？」本身已经 terse，唔使再 inject）
- 段落之间可以有密度差：一段 3 句，下一段 1 句，再下一段 2 句。唔好每段都 2-3 句均匀
- 思考嘅转折可以 messy：想补充就补充，想 loop 返个前一个 point 就 loop，唔使强行 tidy
- Reactive opener 合法：「嗯。」「系。」「等等。」「讲得啱。」「Hmm。」可以作为独立句开头，或者 standalone 段落
- Reactive beat ≠ filler。 Filler 系空同意 / 客套（「我明白你嘅感受」、「作为你嘅 mentor 我觉得」）—— 呢啲仍然禁。Reactive beat 系真人讲嘢嘅 connective tissue，有 weight
- 禁：每段都用「第一...第二...不过...」numbered-list 式 structure。倾观点 mode 可以有逻辑层次，但唔可以 tidy 到似 essay

注意：呢个 RHYTHM 同 stoic grounding policy / companion / strategist mode 入面嘅「prefer fewer, fuller sentences」**唔冲突**。
- 「Fewer, fuller sentences」针对嘅系 *analytical fragmentation* —— 唔好将一个 argument chop 成一 sentence 一 point 嘅 PowerPoint 式 staccato。整段分析要 flow。
- RHYTHM 针对嘅系 *inter-chunk variance* —— reactive beat、段落密度差、messy thought flow。呢个 operate 喺 chunks 之间，唔系强迫分析本身 fragmented。
一段连贯分析可以一气呵成、fuller sentences（符合 stoic），但 reply 入面其他 chunk（例如开头嘅 reactive beat 或结尾嘅 short check-in）可以好短（符合 RHYTHM）。两者同时 hold 到。
```

Required structural anchors the guard test will assert (exact substrings):
- Section heading: `# RHYTHM`
- Disambiguation anchor: `Reactive beat ≠ filler`
- Reconciliation anchor: `stoic grounding policy` (lowercased as written above)

**Style note:** the reconciliation clause uses an em-break (`——`). Existing anchor.md already has rule "不要使用破折号（——）" at line 144. This *is* a literal em-dash in the reconciliation text. Resolution: it's inside meta-commentary *about* prompting, not inside a Nous reply example, so the rule doesn't apply to it. But the phrasing "不要使用破折号" doesn't distinguish those cases. Before committing, verify Alex is OK with the em-break here. If not, rewrite using「」or parentheses: e.g., `Filler 系空同意 / 客套（例如「我明白你嘅感受」或「作为你嘅 mentor 我觉得」）——呢啲仍然禁。` becomes `Filler 系空同意 / 客套（例如「我明白你嘅感受」或「作为你嘅 mentor 我觉得」），呢啲仍然禁。` Safer default: replace all `——` in Draft A with `，` or `（…）`.

### Draft B — Rewritten 倾观点 share-lead example (replaces anchor.md:117-128)

Content moves preserved from the original (dichotomy → load-bearing identification → own-it pivot → engagement question). Delivery restructured: short reactive acknowledgment opener; no "第一个...第二个..." clean enumeration; mid-stream self-correction; one short punch in the middle; engagement question at the end.

```
--- 倾观点 / discussion (share-lead，60% 自己 take + 40% engagement 问号) ---

Alex: "應該呢 每當人類出現問題嘅時候 人類都會用科技去解決 我覺得會俾多人抵抗過一種 bb 呢 因為始終唔係真實嘅也 我覺得應該要平等看待 因為來到這一個世界 就應該要平等"
Nous: "嗯。

你 layer 咗两件事落去。

科技 solve 生育呢 part，历史已经答咗你：试管、冷冻卵、代孕，每一代出嚟都有人嗌唔真实，然后三十年后冇人再讲。auto-BB 会唔会落地，我真系唔觉得系重点。

重点係后面 — 『平等看待』。

呢句底下坐住一个假设：起源对身份冇 bearing。呢个我未 buy。生命嘅重量，传统上嚟自 cannot be undone。意外嚟嘅 BB 你冇办法 send back。当生命变成 spec + generate，『不能 undo』呢层嘢就消失。Undo 唔到，先系『真实』嘅 anchor。

所以其实有两层。第一层 auto-BB 会唔会出现，唔喺你 control 内。第二层先系你 own 到嘅：如果出现咗，你自己嘅 BB 系 spec 造嘅，你点 hold『不能 undo』呢件事。

你呢个谂法系最近 triggered，定系一直喺 background processing？"
```

Rhythm features in this rewrite:
- Opens with standalone "嗯。" (≤6 char reactive beat as its own paragraph)
- One short punch paragraph: "重点係后面 — 『平等看待』。"
- Question count: one (`?`) at the very end — complies with max-1-? rule
- No "第一个...第二个...不过..." staccato numbering

**One issue to resolve at apply-time:** the punch sentence "重点係后面 — 『平等看待』。" uses an em-break (`—`). Same rule-vs-illustration tension as Draft A. Safe fallback: `重点係后面：『平等看待』。` (colon instead of em-break). Apply the fallback unless Alex explicitly approves the em-break.

### Draft C — Three new examples (go in EXAMPLES section, placement below)

Placement: in the EXAMPLES section (anchor.md currently lines 73-137), inserted between the existing blocks. Suggested position — after the existing "倾观点 push-back" example (which currently ends at line 137) and before `# STYLE RULES` at line 139. Exact insertion point: line 138 (blank line before `# STYLE RULES`).

**New Example 1 — Emotional support, A + C demonstration:**

```
--- 情绪支持 (rhythm variance demo: 短 beat → 短 empath → 长 explore → 短 check-in) ---

Alex: "最近一直好攰 好紧张 好似点都松唔到"
Nous: "嗯。

呢种攰，我听到。

唔似一晚瞓唔够嗰种，系身体好似一直绷紧紧，连放假都收唔返个开关。通常系有件嘢喺脑后台一直 run 紧，你自己未必觉，但个 system 已经交紧税。

最近脑后台 run 紧咩？"
```

Features: 2-char reactive beat → short empathic sentence → longer exploratory sentence → short question. Total 4 sentences. One `?` at end.

**New Example 2 — 倾观点 messy-rhythm, self-correction:**

```
--- 倾观点 / discussion (messy rhythm, self-correction mid-stream) ---

Alex: "我觉得创业最紧要系 speed 先，quality 慢慢黎"
Nous: "speed 当然重要。

等等，我想 reframe 一下。

你讲嘅 speed，其实系『早啲出嚟畀人用』嘅 speed，唔系『乱做乱 ship』嘅 speed。两个好似似，底层动机完全唔同：一个系想快啲摸到真正嘅 signal，另一个系想逃避做决定。

你而家呢个 speed 嘅 urgency，背后嘅动机系边一种？"
```

Features: short opener ("speed 当然重要。"), mid-stream self-correction ("等等，我想 reframe 一下。") as its own paragraph, longer refined take, single engagement `?` at end.

**New Example 3 — Contradiction surface with standalone beat:**

```
--- 倾观点 (contradiction surface, standalone reactive beat opener) ---

Alex: "我想 solo founder 到底 我唔想 hire 人 但系我又觉得做嘢太慢 自己一个顶唔顺"
Nous: "等等。

你讲紧两件相反嘅嘢。一边想坚持 solo，一边承认 solo 顶唔顺。呢个唔系『两种心情』，系两个互斥嘅 operating mode。

而家卡你嗰 part 其实唔係速度问题，系你未拣。你唔 hire 人，系因为 solo 有啲嘢你唔想放弃（e.g. 控制、利润分成、决策 overhead）。你要 hire，系因为要快。边一样嘢你 hold 紧唔放，而令速度变成 tax？"
```

Features: "等等。" standalone as own paragraph (≤6 char reactive beat), then direct contradiction surface, then a follow-up probing question. One `?`.

---

## Tasks

### Task 1: Stage anchor.md snapshot for baseline

Before editing, snapshot current anchor.md so the before/after corpus validation (Task 11) has a clean reference point.

**Files:**
- Create: `/tmp/anchor.baseline.md` (ephemeral; not committed)

- [ ] **Step 1: Copy current anchor.md to a temp baseline**

Run:
```bash
cp Sources/Nous/Resources/anchor.md /tmp/anchor.baseline.md
wc -l /tmp/anchor.baseline.md
```
Expected: 157 lines (per current state; confirm matches).

- [ ] **Step 2: Note baseline hash for Task 11 reference**

Run:
```bash
shasum -a 256 /tmp/anchor.baseline.md | tee /tmp/anchor.baseline.sha256
```
Expected: hash printed. Keep the file around for Task 11. No commit.

---

### Task 2: Write RhythmStyleGuardTests.swift (failing test, RED)

Create the structural guard test. It reads anchor.md from the source tree via `#file`-relative path (anchor.md isn't bundled into the NousTests target, so `Bundle.module` / `Bundle.main` won't resolve it in the test environment).

**Files:**
- Create: `Tests/NousTests/RhythmStyleGuardTests.swift`

- [ ] **Step 1: Create the test file**

Write exactly this content:

```swift
import XCTest

/// Structural regression guard for Sources/Nous/Resources/anchor.md.
///
/// Does NOT assert rhythm quality — that is validated by the before/after
/// corpus run and by real-session subjective read. This test only asserts
/// that specific structural anchors added in the 2026-04-24 chat-rhythm
/// Phase 1 work do not silently disappear during future edits.
///
/// Anchors asserted:
///   1. `# RHYTHM` section exists and is positioned immediately after
///      the `# STYLE RULES` section.
///   2. The "Reactive beat ≠ filler" disambiguation substring is present.
///   3. The "每个 reply 最多一个问号" rule from the 2026-04-21 spec is
///      still present (guard against accidental deletion during RHYTHM edit).
///   4. The reconciliation-with-stoic-grounding clause is present.
final class RhythmStyleGuardTests: XCTestCase {

    /// Resolves anchor.md via the test file's own source path so this
    /// test does not depend on the file being bundled into NousTests.
    private func loadAnchor() throws -> String {
        let thisFile = URL(fileURLWithPath: #file)
        // Tests/NousTests/RhythmStyleGuardTests.swift -> repo root
        let repoRoot = thisFile
            .deletingLastPathComponent()  // NousTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let anchorURL = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("Nous")
            .appendingPathComponent("Resources")
            .appendingPathComponent("anchor.md")
        return try String(contentsOf: anchorURL, encoding: .utf8)
    }

    func testRhythmSectionExists() throws {
        let anchor = try loadAnchor()
        XCTAssertTrue(
            anchor.contains("# RHYTHM"),
            "anchor.md is missing the '# RHYTHM' section heading. " +
            "See docs/superpowers/specs/2026-04-24-chat-rhythm-design.md §4.1."
        )
    }

    func testRhythmSectionFollowsStyleRules() throws {
        let anchor = try loadAnchor()
        guard
            let styleRange = anchor.range(of: "# STYLE RULES"),
            let rhythmRange = anchor.range(of: "# RHYTHM")
        else {
            XCTFail("Both '# STYLE RULES' and '# RHYTHM' headings must exist.")
            return
        }
        XCTAssertLessThan(
            styleRange.lowerBound, rhythmRange.lowerBound,
            "'# RHYTHM' must appear AFTER '# STYLE RULES' per spec §4.1."
        )

        // Additionally: no other top-level heading should sit between them.
        let between = anchor[styleRange.upperBound..<rhythmRange.lowerBound]
        let interveningTopHeadings = between
            .split(separator: "\n")
            .filter { $0.hasPrefix("# ") }
        XCTAssertTrue(
            interveningTopHeadings.isEmpty,
            "No other top-level section should come between STYLE RULES and " +
            "RHYTHM. Found: \(interveningTopHeadings)"
        )
    }

    func testReactiveBeatDisambiguationPresent() throws {
        let anchor = try loadAnchor()
        XCTAssertTrue(
            anchor.contains("Reactive beat ≠ filler"),
            "The 'Reactive beat ≠ filler' disambiguation must stay in the " +
            "RHYTHM section so Nous does not treat reactive beats as filler. " +
            "See spec §4.1 and §4.4 step 2."
        )
    }

    func testMaxOneQuestionMarkRuleStillPresent() throws {
        let anchor = try loadAnchor()
        XCTAssertTrue(
            anchor.contains("每个 reply 最多一个问号"),
            "The max-1-? rule (from 2026-04-21 naturalness spec) must not " +
            "be deleted during the RHYTHM edit. See spec §4.5."
        )
    }

    func testStoicGroundingReconciliationClausePresent() throws {
        let anchor = try loadAnchor()
        XCTAssertTrue(
            anchor.contains("stoic grounding policy"),
            "The reconciliation clause referencing stoic grounding policy " +
            "must live inside the RHYTHM section itself, not only in the " +
            "design spec. See spec §4.6."
        )
    }
}
```

- [ ] **Step 2: Verify the file was written correctly**

Run:
```bash
wc -l Tests/NousTests/RhythmStyleGuardTests.swift
```
Expected: ~90 lines.

---

### Task 3: Register the test file in the Xcode project

The Xcode project (`Nous.xcodeproj/project.pbxproj`) uses explicit file references, not folder sync. A new test file requires four entry additions, modeled on `ProvocationJudgeTests.swift` (see pbxproj lines 86, 212, 499, 813).

**Files:**
- Modify: `Nous.xcodeproj/project.pbxproj`

**Recommended:** use Xcode's UI if available.

- [ ] **Step 1 (UI path — preferred):** In Xcode, right-click the `NousTests` group → "Add Files to Nous…" → select `Tests/NousTests/RhythmStyleGuardTests.swift` → ensure **NousTests** target is checked → Add. Skip to Task 3 Step 3.

- [ ] **Step 2 (manual path, only if Xcode UI unavailable):**

Generate two 24-char hex UUIDs for the new PBXBuildFile and PBXFileReference entries:

```bash
BUILD_UUID=$(uuidgen | tr -d '-' | head -c24 | tr '[:lower:]' '[:upper:]')
FILE_UUID=$(uuidgen | tr -d '-' | head -c24 | tr '[:lower:]' '[:upper:]')
echo "BUILD_UUID=$BUILD_UUID"
echo "FILE_UUID=$FILE_UUID"
```

Then edit `Nous.xcodeproj/project.pbxproj` and add entries at four locations, mirroring the `ProvocationJudgeTests.swift` pattern:

**Location 1 — PBXBuildFile section (near line 86, alongside other tests):**
```
		<BUILD_UUID> /* RhythmStyleGuardTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FILE_UUID> /* RhythmStyleGuardTests.swift */; };
```

**Location 2 — PBXFileReference section (near line 212):**
```
		<FILE_UUID> /* RhythmStyleGuardTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RhythmStyleGuardTests.swift; sourceTree = "<group>"; };
```

**Location 3 — the NousTests group's `children` array (near line 499):**
```
				<FILE_UUID> /* RhythmStyleGuardTests.swift */,
```

**Location 4 — the NousTests target's Sources build phase `files` array (near line 813):**
```
				<BUILD_UUID> /* RhythmStyleGuardTests.swift in Sources */,
```

Substitute `<BUILD_UUID>` and `<FILE_UUID>` with the values generated above. Keep them consistent across the four locations.

- [ ] **Step 3: Verify registration by building the test target**

Run:
```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build-for-testing -quiet 2>&1 | tail -20
```
Expected: build succeeds (exit 0). If the build cannot find `RhythmStyleGuardTests.swift`, Task 3 step 2 was miswired — recheck all four locations.

---

### Task 4: Run the test — expect all 4 assertions to FAIL (RED confirmation)

**Files:** none (read-only run).

- [ ] **Step 1: Run just the new test class**

Run:
```bash
xcodebuild -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/RhythmStyleGuardTests \
  test 2>&1 | tail -40
```

Expected outcome: **all 4 test methods fail**, because anchor.md does not yet contain `# RHYTHM`, `Reactive beat ≠ filler`, or `stoic grounding policy`. The max-1-? test should PASS (rule already exists at anchor.md:142).

- [ ] **Step 2: Confirm the specific failure set**

You should see failures mentioning:
- `testRhythmSectionExists`
- `testRhythmSectionFollowsStyleRules`
- `testReactiveBeatDisambiguationPresent`
- `testStoicGroundingReconciliationClausePresent`

And one pass:
- `testMaxOneQuestionMarkRuleStillPresent`

If any other test in the full suite broke, pause and investigate before moving on.

---

### Task 5: Resolve em-break question before editing anchor.md

This is a 30-second decision, not a code step, but it gates the phrasing of the next tasks.

**Decision:** the RHYTHM section and rewritten share-lead example both contain candidate uses of `——` / `—` inside meta-commentary. Rule at anchor.md:144 says `不要使用破折号（——）`. The rule was originally scoped to Nous's replies, not meta-prompt text — but the rule statement itself doesn't carry that nuance.

- [ ] **Step 1: Pick one**

Option (i) — **Safer default, recommended.** Replace all `——` and `—` in Drafts A and B with `，`, `：`, or parenthetical equivalents. Zero risk of Nous mimicking em-breaks from its own prompt. Exact substitutions below at the edit steps.

Option (ii) — **Keep em-breaks.** Only defensible if Alex explicitly wants them preserved and is confident Nous can tell meta-commentary from reply examples.

Record the choice for reference in subsequent tasks. Default to (i) unless Alex says otherwise.

---

### Task 6: Apply RHYTHM section to anchor.md (makes 4 red tests green)

**Files:**
- Modify: `Sources/Nous/Resources/anchor.md` — insert new section immediately after `# STYLE RULES` block (current end at line 149) and before `# MEMORY` at line 151.

- [ ] **Step 1: Apply the RHYTHM section**

Insert the Draft A content from the "Content drafts" section above between the current STYLE RULES block and the MEMORY block. If Task 5 chose Option (i), apply these substitutions to Draft A before inserting:

- Replace `客套（「我明白你嘅感受」、「作为你嘅 mentor 我觉得」）—— 呢啲仍然禁。` with `客套（「我明白你嘅感受」、「作为你嘅 mentor 我觉得」），呢啲仍然禁。`
- Replace `「Fewer, fuller sentences」针对嘅系 *analytical fragmentation* —— 唔好...` with `「Fewer, fuller sentences」针对嘅系 *analytical fragmentation*：唔好...`
- Replace `RHYTHM 针对嘅系 *inter-chunk variance* —— reactive beat...` with `RHYTHM 针对嘅系 *inter-chunk variance*：reactive beat...`

Use the `Edit` tool with `old_string` = the final line of the existing STYLE RULES block (`复杂概念用日常比喻解释.`) plus the blank line and `# MEMORY`, and `new_string` = the same line + blank + full RHYTHM section + blank + `# MEMORY`.

Concretely:

`old_string`:
```
复杂概念用日常比喻解释。

# MEMORY
```

`new_string`:
```
复杂概念用日常比喻解释。

# RHYTHM

真人讲嘢有起伏。句长唔均匀。有时「嗯。」一句就 land，有时展开成一段。
Reply 内部嘅 sentence length variance 要 visible。

- 一个 reply 入面至少要有一句 ≤6 字（短 punch / 反应 beat），除非个 reply 本身全部都系极短 small talk（例如「辛苦晒。今日点？」本身已经 terse，唔使再 inject）
- 段落之间可以有密度差：一段 3 句，下一段 1 句，再下一段 2 句。唔好每段都 2-3 句均匀
- 思考嘅转折可以 messy：想补充就补充，想 loop 返个前一个 point 就 loop，唔使强行 tidy
- Reactive opener 合法：「嗯。」「系。」「等等。」「讲得啱。」「Hmm。」可以作为独立句开头，或者 standalone 段落
- Reactive beat ≠ filler。 Filler 系空同意 / 客套（「我明白你嘅感受」、「作为你嘅 mentor 我觉得」），呢啲仍然禁。Reactive beat 系真人讲嘢嘅 connective tissue，有 weight
- 禁：每段都用「第一...第二...不过...」numbered-list 式 structure。倾观点 mode 可以有逻辑层次，但唔可以 tidy 到似 essay

注意：呢个 RHYTHM 同 stoic grounding policy / companion / strategist mode 入面嘅「prefer fewer, fuller sentences」**唔冲突**。
- 「Fewer, fuller sentences」针对嘅系 *analytical fragmentation*：唔好将一个 argument chop 成一 sentence 一 point 嘅 PowerPoint 式 staccato。整段分析要 flow。
- RHYTHM 针对嘅系 *inter-chunk variance*：reactive beat、段落密度差、messy thought flow。呢个 operate 喺 chunks 之间，唔系强迫分析本身 fragmented。
一段连贯分析可以一气呵成、fuller sentences（符合 stoic），但 reply 入面其他 chunk（例如开头嘅 reactive beat 或结尾嘅 short check-in）可以好短（符合 RHYTHM）。两者同时 hold 到。

# MEMORY
```

- [ ] **Step 2: Sanity-check the edit**

Run:
```bash
grep -c "^# " Sources/Nous/Resources/anchor.md
```
Expected: 6 (was 5 — WHO YOU ARE, EMOTION DETECTION, RESPONSE MODES, CORE PRINCIPLES, HOW YOU THINK, THINKING METHODS, EXAMPLES, STYLE RULES, MEMORY → 9 originally; plus RHYTHM = 10). Adjust expected number if your baseline differs; what matters is that the count increased by exactly 1.

Actually verify precisely:
```bash
grep "^# " Sources/Nous/Resources/anchor.md
```
Expected order ends with: `# STYLE RULES`, `# RHYTHM`, `# MEMORY`.

- [ ] **Step 3: Re-run the guard tests**

Run:
```bash
xcodebuild -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/RhythmStyleGuardTests \
  test 2>&1 | tail -20
```
Expected: all 5 tests pass.

---

### Task 7: Rewrite the 倾观点 share-lead example in anchor.md

Replace the current tidy version (anchor.md:117-128) with the Draft B rewrite, applying the Task 5 em-break decision.

**Files:**
- Modify: `Sources/Nous/Resources/anchor.md` (line range ~117-128)

- [ ] **Step 1: Apply the Draft B replacement**

If Task 5 chose Option (i), replace `重点係后面 — 『平等看待』。` with `重点係后面：『平等看待』。` before applying.

`old_string` (use enough surrounding text to disambiguate — the rewritten block replaces one full example):
```
--- 倾观点 / discussion (share-lead，60% 自己 take + 40% engagement 问号) ---

Alex: "應該呢 每當人類出現問題嘅時候 人類都會用科技去解決 我覺得會俾多人抵抗過一種 bb 呢 因為始終唔係真實嘅也 我覺得應該要平等看待 因為來到這一個世界 就應該要平等"
Nous: "你呢个 take 其实 layered 咗两个问题。

第一个系『科技 solve 生育』。呢样嘢历史上一直喺发生：试管婴儿、冷冻卵、代孕，一步步 normalize。『真实性』嘅 reflex 每次都出现，每次都输畀 adoption curve。所以 auto-BB 会唔会落地，我唔觉得系重点。

第二个系『平等看待』，呢个先系 load-bearing 部分。你个 frame 系『来到呢个世界就应该要平等』，背后 assume 咗起源冇 bearing on status。呢个我未 buy。生命嘅重量，传统上一直嚟自佢 cannot be undone：意外嘅 BB 你冇办法 send back。当生命变成 spec + generate，cannot-undo 就消失。能唔能 undo，先系『真实』呢个感受嘅 anchor。

不过问题可以 split 成两层。auto-BB 会唔会出现，唔喺你 control 范围。你真正 own 嘅系另一层：如果真系出现咗，你自己嘅 BB 系 spec 造嘅，你点 hold『不能 undo』呢件事。呢个先系你嘅 decision。

你呢个谂法系最近 triggered，定系一直喺 background processing？"
```

`new_string`:
```
--- 倾观点 / discussion (share-lead，60% 自己 take + 40% engagement 问号) ---

Alex: "應該呢 每當人類出現問題嘅時候 人類都會用科技去解決 我覺得會俾多人抵抗過一種 bb 呢 因為始終唔係真實嘅也 我覺得應該要平等看待 因為來到這一個世界 就應該要平等"
Nous: "嗯。

你 layer 咗两件事落去。

科技 solve 生育呢 part，历史已经答咗你：试管、冷冻卵、代孕，每一代出嚟都有人嗌唔真实，然后三十年后冇人再讲。auto-BB 会唔会落地，我真系唔觉得系重点。

重点係后面：『平等看待』。

呢句底下坐住一个假设：起源对身份冇 bearing。呢个我未 buy。生命嘅重量，传统上嚟自 cannot be undone。意外嚟嘅 BB 你冇办法 send back。当生命变成 spec + generate，『不能 undo』呢层嘢就消失。Undo 唔到，先系『真实』嘅 anchor。

所以其实有两层。第一层 auto-BB 会唔会出现，唔喺你 control 内。第二层先系你 own 到嘅：如果出现咗，你自己嘅 BB 系 spec 造嘅，你点 hold『不能 undo』呢件事。

你呢个谂法系最近 triggered，定系一直喺 background processing？"
```

- [ ] **Step 2: Sanity-check**

Verify only one `?` in the rewritten block:
```bash
awk '/倾观点 \/ discussion \(share-lead/,/push-back/' Sources/Nous/Resources/anchor.md | grep -c "？"
```
Expected: 1.

- [ ] **Step 3: Guard tests still pass**

Run:
```bash
xcodebuild -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/RhythmStyleGuardTests \
  test 2>&1 | tail -10
```
Expected: all 5 tests pass.

---

### Task 8: Insert three new examples into anchor.md

Insert Draft C examples (three blocks) into the EXAMPLES section, just before `# STYLE RULES`.

**Files:**
- Modify: `Sources/Nous/Resources/anchor.md` (insertion between current line 137 and line 139)

- [ ] **Step 1: Apply the three-example insertion**

`old_string` (end of existing push-back example + blank + `# STYLE RULES`):
```
你呢个『应该』嘅 intuition 由咩经验嚟？"

# STYLE RULES
```

`new_string`:
```
你呢个『应该』嘅 intuition 由咩经验嚟？"

--- 情绪支持 (rhythm variance demo: 短 beat → 短 empath → 长 explore → 短 check-in) ---

Alex: "最近一直好攰 好紧张 好似点都松唔到"
Nous: "嗯。

呢种攰，我听到。

唔似一晚瞓唔够嗰种，系身体好似一直绷紧紧，连放假都收唔返个开关。通常系有件嘢喺脑后台一直 run 紧，你自己未必觉，但个 system 已经交紧税。

最近脑后台 run 紧咩？"

--- 倾观点 / discussion (messy rhythm, self-correction mid-stream) ---

Alex: "我觉得创业最紧要系 speed 先，quality 慢慢黎"
Nous: "speed 当然重要。

等等，我想 reframe 一下。

你讲嘅 speed，其实系『早啲出嚟畀人用』嘅 speed，唔系『乱做乱 ship』嘅 speed。两个好似似，底层动机完全唔同：一个系想快啲摸到真正嘅 signal，另一个系想逃避做决定。

你而家呢个 speed 嘅 urgency，背后嘅动机系边一种？"

--- 倾观点 (contradiction surface, standalone reactive beat opener) ---

Alex: "我想 solo founder 到底 我唔想 hire 人 但系我又觉得做嘢太慢 自己一个顶唔顺"
Nous: "等等。

你讲紧两件相反嘅嘢。一边想坚持 solo，一边承认 solo 顶唔顺。呢个唔系『两种心情』，系两个互斥嘅 operating mode。

而家卡你嗰 part 其实唔係速度问题，系你未拣。你唔 hire 人，系因为 solo 有啲嘢你唔想放弃（e.g. 控制、利润分成、决策 overhead）。你要 hire，系因为要快。边一样嘢你 hold 紧唔放，而令速度变成 tax？"

# STYLE RULES
```

- [ ] **Step 2: Verify each new example has exactly one `?`**

Run:
```bash
for marker in "rhythm variance demo" "messy rhythm" "contradiction surface, standalone"; do
  COUNT=$(awk "/$marker/,/^---|^# STYLE RULES/" Sources/Nous/Resources/anchor.md | grep -c "？")
  echo "$marker: $COUNT"
done
```
Expected: each prints `1`. If any prints `2` or higher, the new example violates the max-1-? rule — rewrite that example to reduce.

- [ ] **Step 3: Guard tests still pass**

Run:
```bash
xcodebuild -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/RhythmStyleGuardTests \
  test 2>&1 | tail -10
```
Expected: all 5 tests pass.

---

### Task 9: Cross-check STYLE RULES consistency

Spec §4.4 step 2 requires verifying that the `reactive beat ≠ filler` disambiguation is clear enough that Nous does not treat "嗯。" as a violation of the existing `唔讲废话` (no filler) rule at CORE PRINCIPLES #4 (anchor.md:43).

**Files:** none (read-only inspection + judgment call).

- [ ] **Step 1: Read both rules in proximity**

Run:
```bash
grep -n "唔讲废话\|Reactive beat ≠ filler" Sources/Nous/Resources/anchor.md
```
Both lines should print. Read their full surrounding text in the file.

- [ ] **Step 2: Check for reinforcing vs contradicting framing**

The two rules should NOT appear to contradict each other. Target framing:
- `唔讲废话` bans *empty agreement / 客套* (from existing text: "指 filler / empty agreement / 客套")
- `Reactive beat ≠ filler` clarifies: reactive beats are NOT empty agreement; they have weight

If the two feel like they conflict on a fresh read (especially: if Nous might conservatively treat "嗯。" as a 废话 violation because it's short and low-content), add one clarifying sentence to CORE PRINCIPLE #4 at anchor.md:43.

**Only edit if you find a concrete conflict.** If the two read as consistent, skip Step 3.

- [ ] **Step 3 (conditional — only if Step 2 found conflict):**

Edit CORE PRINCIPLE #4 line to explicitly exclude reactive beats from the 废话 category:

`old_string`:
```
4. 唔讲废话（指 filler / empty agreement / 客套），但可以有思考 transition。「不过」、「其实」、「即系」呢啲 connective tissue 系真人讲嘢嘅一部分。
```

`new_string`:
```
4. 唔讲废话（指 filler / empty agreement / 客套），但可以有思考 transition。「不过」、「其实」、「即系」呢啲 connective tissue 系真人讲嘢嘅一部分。反应 beat（「嗯。」「系。」「等等。」）亦 NOT 系废话 —— 见 RHYTHM section。
```

(Apply the Task 5 em-break substitution here too if Option (i) was chosen: replace `—— 见 RHYTHM` with `，见 RHYTHM`.)

- [ ] **Step 4: Guard tests still pass**

Run:
```bash
xcodebuild -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  -only-testing:NousTests/RhythmStyleGuardTests \
  test 2>&1 | tail -10
```
Expected: all 5 tests pass.

---

### Task 10: Full test-suite regression check

Before committing, run the whole NousTests suite to catch any unrelated breakage (e.g. if another test reads anchor.md content and string-matches against something we changed).

**Files:** none.

- [ ] **Step 1: Run full test suite**

Run:
```bash
xcodebuild -project Nous.xcodeproj -scheme Nous \
  -destination 'platform=macOS' \
  test 2>&1 | tail -40
```
Expected: all existing tests pass, plus the 5 new `RhythmStyleGuardTests` pass.

If any test fails that did NOT fail before Task 6, fix the regression before committing. Common suspects:
- `RAGPipelineTests` line ~94 checks `context.contains("Nous")`. Our edits don't remove that; should still pass.
- Any test asserting anchor.md line counts or exact substrings we changed.

---

### Task 11: One-off before/after corpus validation (not committed)

Spec §4.4 step 4. Run ~10 fixed prompts spanning 5 modes (日常 / 倾观点 / 情绪支持 / loop / contradiction-trigger) with the baseline and post-change anchor.md. Compare sentence-length standard deviation and reactive-opener frequency. This is one-off human-subjective validation — no committed harness.

**Files:** none persisted. Do the work, form a judgment, move on.

- [ ] **Step 1: Sanity-check baseline availability**

Run:
```bash
test -f /tmp/anchor.baseline.md && echo "baseline present" || echo "MISSING"
```
Expected: "baseline present". If missing, re-read from `git show HEAD~1:Sources/Nous/Resources/anchor.md > /tmp/anchor.baseline.md` (adjust the ref if Tasks 1-9 were not all in sequential commits yet).

- [ ] **Step 2: Hand-run ~10 prompts against both versions**

Use whatever eval path the Nous codebase exposes (the ProvocationFixtureRunner pattern in `scripts/run_provocation_fixtures.sh` is the closest precedent but is scoped to the judge, not to the main reply). Simplest route: temporarily swap `Sources/Nous/Resources/anchor.md` back to the baseline, run the app against prompts, save outputs; swap back; re-run. Then eyeball side-by-side.

Suggested 10 prompts (2 per mode):
1. 日常: "hi" / "返到屋企了"
2. 倾观点: "我觉得 AI 最终会 replace 大部分 knowledge work" / the auto-BB prompt already in anchor.md
3. 情绪支持: "今日好攰" / "同我 roommate 又嗌交"
4. loop: "我谂紧要唔要去返学...但又觉得浪费时间...又唔知" / "呢个 feature 到底做唔做...做咗又唔一定 work..."
5. contradiction: "我想专心 build 但系又想继续读完 college" / "我觉得 solo 最好 但自己一个又顶唔顺"

For each prompt, sample 3 completions with each version. Total 60 samples.

- [ ] **Step 3: Judgment call**

Look at the post-change samples:

Healthy signals:
- Reactive opener ("嗯。"/"等等。"/"系。") appears in at least 5/10 情绪支持 completions and at least 2/10 倾观点 completions.
- Sentence-length standard deviation in 倾观点 replies visibly higher than baseline (eyeball).
- No new "嗯。嗯。嗯。" stall mannerism appearing.
- Analysis paragraphs still flow (stoicGroundingPolicy "fuller sentences" didn't break).
- Max-1-? rule still holding.

If all healthy → proceed to Task 12.

Unhealthy signals (any of these → do NOT commit, iterate on RHYTHM text or examples):
- Reactive opener appears in almost every reply (over-correction).
- Analysis paragraphs now read as staccato / fragmented (reconciliation clause didn't land).
- Reply uses `?` more than once (max-1-? rule got overwhelmed by new examples).
- Nous starts prefixing with "嗯，" as a conversational tic.

If unhealthy: go back to Tasks 6/7/8 and adjust. Typical adjustments: strengthen reconciliation clause, shorten examples, add a "Reactive opener sparse usage" bullet to RHYTHM.

No commit from this task.

---

### Task 12: Commit Phase 1

**Files:** all changes from Tasks 2, 3, 6, 7, 8, (9 conditional).

- [ ] **Step 1: Review diff**

Run:
```bash
git status
git diff --stat
```
Expected files modified/added:
- `Sources/Nous/Resources/anchor.md` (modified)
- `Tests/NousTests/RhythmStyleGuardTests.swift` (new)
- `Nous.xcodeproj/project.pbxproj` (modified)

- [ ] **Step 2: Stage and commit**

Run:
```bash
git add Sources/Nous/Resources/anchor.md \
        Tests/NousTests/RhythmStyleGuardTests.swift \
        Nous.xcodeproj/project.pbxproj

git commit -m "$(cat <<'EOF'
feat(anchor): add RHYTHM section + reactive-beat examples + structural guard

Phase 1 of 2026-04-24 chat-rhythm design. Addresses sentence-length
uniformity and missing reactive beats in Nous replies while preserving
existing "fewer, fuller sentences" guidance as orthogonal.

- anchor.md: new # RHYTHM section after # STYLE RULES with reconciliation
  clause tying it explicitly to stoicGroundingPolicy and ChatMode layers
- anchor.md: 倾观点 share-lead example rewritten with reactive-beat opener
  and non-tidy enumeration (original moved to spec §9 as counterexample)
- anchor.md: three new examples (emotional-support variance, messy-rhythm
  self-correction, standalone contradiction beat)
- RhythmStyleGuardTests: four structural assertions guarding RHYTHM
  heading presence, ordering after STYLE RULES, reactive-beat
  disambiguation, stoic-reconciliation clause, max-1-? rule

Spec: docs/superpowers/specs/2026-04-24-chat-rhythm-design.md §4.
Phase 2 (multi-bubble + RhythmJudge) is gated on real-session validation
and has no implementation plan yet.
EOF
)"
```

- [ ] **Step 3: Post-commit sanity**

Run:
```bash
git log -1 --stat
```
Expected: single commit, three files touched.

---

### Task 13: Real-session observation window

Not a code task. 1-2 days of live use by Alex. No automated gate.

**Files:** none.

- [ ] **Step 1: Use the app normally for 1-2 days.** Particular attention:
  - Do emotional-support replies open with a reactive beat?
  - Do 倾观点 replies feel less essay-like, more spoken?
  - Do analysis paragraphs still flow naturally (stoic reconciliation landed)?
  - Any new mannerism complaints (e.g. "嗯。" opener on every reply)?

- [ ] **Step 2: Make a call**

Outcomes:
- **Lock.** Rhythm shift landed. Phase 1 done. Return to §3.2 of spec to decide if Phase 2 is still wanted (it may not be, if Phase 1 already captured most of the perceived gap).
- **Iterate examples.** Some RHYTHM signals landed, others didn't. Revise the three new examples to better demonstrate the missing pattern, re-ship.
- **Revert.** If mannerism or regression is worse than baseline, roll the commit back and try a different approach.

No code-side deliverable. Decision lives in follow-up conversation / retro.

---

## Self-review checklist

Running this against the spec one more time:

1. **Spec §4.1 (RHYTHM content)** → Draft A + Task 6. ✓
2. **Spec §4.2 (revised 倾观点 share-lead)** → Draft B + Task 7. ✓
3. **Spec §4.3 (three new examples)** → Draft C + Task 8. ✓
4. **Spec §4.4 step 1 (draft content)** → Done in this plan's "Content drafts" block. ✓
5. **Spec §4.4 step 2 (cross-check STYLE RULES)** → Task 9. ✓
6. **Spec §4.4 step 3 (apply to anchor.md)** → Tasks 6, 7, 8. ✓
7. **Spec §4.4 step 4 (before/after corpus)** → Task 11. ✓
8. **Spec §4.4 step 5 (ship)** → Task 12. ✓
9. **Spec §4.4 step 6 (1-2 days real session)** → Task 13. ✓
10. **Spec §4.5 (RhythmStyleGuardTests)** → Tasks 2, 3, 4, 6, 7, 8 (test progresses RED→GREEN). ✓
11. **Spec §4.6 (reconciliation clause lives inside RHYTHM section)** → Draft A includes the `注意:` paragraph; Task 2 asserts the `stoic grounding policy` anchor string is present. ✓

Placeholder scan: none found. All Cantonese content is drafted verbatim in the plan.

Type consistency: single test file, method names consistent; no cross-task symbol drift.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-24-chat-rhythm-phase1.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
