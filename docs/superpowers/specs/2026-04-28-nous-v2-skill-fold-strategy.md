# Nous v2.0 — Skill Fold + Personal Instrument Strategy (Path B)

**Date:** 2026-04-28
**Status:** Strategic spec, Path B (private instrument). Rewritten 2026-04-27 after Codex challenge identified the original mixed-posture spec was a polish-forever trap.
**Author:** Alex Ko, with assistance.

## Strategic decision: Path B

**Nous is Alex's private thinking instrument.**

Future public release is **optional, not load-bearing**. Capacity for sharing later is preserved through 3 minimal architectural hooks (see "Future-readiness hooks" below) but the project is NOT designed as a startup.

### Why Path B

1. **Internally consistent.** Path A (build single-user but pretend multi-user-ready) requires scope cuts + external pressure + revenue deadline; solo founder + F-1 visa cannot do all three. Path B drops the pretense, every decision aligns to one frame.
2. **罗福莉 frame's 「另类阿尔法」 is purest at single-user × time depth.** Alex's pain is the entire validation surface; one year of his real usage produces the alpha that no shallow multi-user product can replicate.
3. **Capital-efficient given founder reality.** Path B is the only posture that lets Alex sustain 5 months of deep work without simulating a startup he doesn't have the runway to build.

### What this means concretely

- Roadmap focuses on Alex's daily thinking quality, not user-acquisition metrics
- 0 revenue accepted; **financial runway must come from independent income source** (consulting / part-time / savings) — Nous is craft work, not the income engine
- "Open up someday" = optional future Phase, not a deadline. Sleep-on-it commitment: Alex accepts that Nous may never have external users.
- Multi-user infrastructure deferred to potential v3, not v2 scope

## Context: 罗福莉's frame, narrowed

The 罗福莉 / 张小珺 interview (2026-04 early) advocates a layered procedural memory architecture for Agent products. We test **one hypothesis** from that frame:

> **"Explicit procedural memory, authored by a power user over a year, makes daily thinking sessions measurably better."**

This is a hypothesis to test, not a moat claim. We are not implementing EverMind's vision; we are isolating one component to validate in our specific context. If the hypothesis fails, we revert.

The article's other claims (Memory→Post-train feedback, 24/7 multimodal device) come from a model/team/company vantage point and do **not** translate to a solo macOS app. We acknowledge the limitation.

## Future-readiness hooks (3 zero-cost decisions)

These preserve the future-public option without compromising single-user quality. Cost: < 1 day of work; benefit: ~6-8 weeks shaved off any future public refactor.

### Hook 1: SQLite schema with `user_id` column (always = 'alex')

```sql
CREATE TABLE skills (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL DEFAULT 'alex',  -- permanently 'alex' in v2
    payload TEXT NOT NULL,                  -- portable JSON, see Hook 2
    ...
);
```

Same pattern for memory atoms, preference entries, anything personal. Cost now: 1 schema column. Benefit later: avoids 1-2 weeks of migration + query rewrites.

### Hook 2: Skill data stored as portable JSON payload

Skills serialize as JSON, not Swift-internal types. SQLite `json1` extension supports native operations.

Pros:
- Schema evolution: add new fields by editing JSON, no `ALTER TABLE`
- Future export: dump table = portable file
- Debug-friendly: `json_extract(payload, '$.trigger_when')` for queries

Cost now: 0 (one decision at schema design time). Benefit later: portable export + import + format-stability.

### Hook 3: Anchor identity vs Alex personal — concept only

**No code change required now.** Anchor.md stays frozen, written极致 personal as Alex wants.

The hook: Alex acknowledges (in this spec, in his head) that ~5% of anchor content is Alex-specific (Cantonese preference, stoic tone, no-advice-list rule). At the time of any future public refactor, this 5% gets scanned and migrated to a `user_facts` overlay.

**During v2 (single-user phase): zero discipline burden.** Alex writes anchor however极致 he wants. Forget about future refactor.

The "scan and extract" is a future-Phase task, not a v2 task.

## Skill Fold core design (v2 minimal)

### Schema

```sql
CREATE TABLE skills (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL DEFAULT 'alex',
    payload TEXT NOT NULL,         -- JSON: {name, description, trigger_when, action_what, priority, source, created_at, last_modified_at}
    state TEXT NOT NULL,           -- 'active' | 'retired'
    fired_count INTEGER DEFAULT 0,
    created_at DATETIME NOT NULL,
    last_modified_at DATETIME NOT NULL
);

CREATE INDEX idx_skills_active ON skills(user_id, state);
```

Note: success/fail counts, A/B variants, auto-promote/retire fields are deferred. v2 starts simple.

### Components (v2)

1. **SkillStore** — SQLite-backed CRUD service
2. **SkillMatcher** — given turn context, returns ranked applicable skills (priority + recency only in v2; no statistical learning)
3. **Dev trace inspector** — *NOT* a polished UI. Console / debug-overlay showing which skills fired this turn, with raw payload. Trust beats beauty.
4. **Migrator** — one-time: convert hardcoded mode addendum (Direction / Brainstorm / Plan) into seed skills

### Design principles

1. **Skill is explicit + addressable** — Alex can see "skill X fired Y times" via dev trace.
2. **Mode contract = special skills** — Direction / Brainstorm / Plan addenda become mode-gated skill rows.
3. **No conflict learning in v2** — if skills conflict at runtime, Alex resolves via priority field manually.
4. **Cap active skills per turn at 3** — per Codex critique #6, more than 3 simultaneously-active skills creates unmanageable conflict surface.
5. **No LLM-as-author** — Alex authors all skills manually in v2. LLM Discover mode deferred.

## Reduced roadmap (~11 weeks until first decision)

| Phase | Scope | 时间 |
|---|---|---|
| 1.0 | Phase 1 ship (tool use + reasoning loop, per `2026-04-27-quick-action-agents-phase1-ab-design.md`) | 4 周（已经做紧） |
| 2.1 | SkillStore schema (with hooks 1+2) + SkillMatcher + dev trace inspector | 2 周 |
| 2.2 | 10 manually authored seed skills (3 modes' contracts → seed skills + Alex's explicit taste) | 1 周 |
| 2.3 | 30-day dogfood — Alex uses Nous daily, observes whether 10 skills make thinking measurably better | 4 周（overlaps daily use） |

**Total: ~11 weeks to first decision point.**

After Phase 2.3, evaluate:

- ☐ The 10 skills measurably improve daily thinking (Alex's subjective + concrete examples logged during dogfood)
- ☐ Skill Fold mechanism is debuggable + maintainable for Alex alone
- ☐ Alex still wants to build more, not less

**If yes → continue to Skill Fold v2.5** (+more skills, basic Skill UI, A/B testing if needed).
**If no → revert investment.** Skill Fold thesis falsified for Alex's context. Pour energy into other Nous improvements (memory polish, mode tuning, etc.).

## What's CUT from original spec draft

Per Codex challenge findings (2026-04-27, session id `019dd270-5262-7e52-9175-7b0c79bc9298` saved at `.context/codex-session-id`):

- ❌ **Skill export/import as v2 feature** — defer to public refactor; export-only inert definitions if ever shipped
- ❌ **Privacy-by-default formal spec** — defer until needed; v2 is local-only by definition
- ❌ **Open-up criteria with quantification** — replaced with "decide later, no committed timeline" (the original 5 checkboxes were founder cope per Codex #4)
- ❌ **Multimodal Phase 4 (screen capture + OCR)** — out of v2 entirely; Codex #12 correct (3-week budget was fantasy)
- ❌ **First-class Skill UI** — replaced by dev-grade trace inspector; Codex #7 correct (real Skill UI is multi-month)
- ❌ **A/B variant testing** — defer until 30+ skills accumulated and signal-to-noise justifies
- ❌ **Auto-promote/retire** — defer; Codex #5 correct (success/fail labels too noisy in v2)
- ❌ **LLM-assist Discover mode** — defer; Alex authors manually in v2
- ❌ **"Soft post-train" framing** — reframed as "retrieval-time policy composition" per Codex #8
- ❌ **"85% of vision achieved" claim** — dropped; Codex #9 correct (self-deception)
- ❌ **Skill Fold as moat** — reframed as hypothesis; Codex top-3 finding #3 correct (private procedural memory layer is not a moat by itself)

## Honest risks (Path B specific)

1. **Polish-forever trap remains real even at Path B.** Mitigation: hard decision point at week 11. If 10 skills don't measurably improve thinking, revert. Don't extend the experiment.
2. **Evaluation time per skill is the hidden multiplier.** Phase 2.2 budgets 1 week for 10 skills, but each skill may need 1-2 ablation rounds (per Direction implementation lesson 2026-04-27). Real time may be 2-3 weeks. Accept it; the hooks are robust to slippage.
3. **Financial runway must be solved separately.** This spec does NOT plan for revenue. F-1 visa + 5 months of zero income from Nous = Alex needs independent runway source. If that's not in place, this entire spec is wrong path.
4. **Market may shift in 12+ months.** Accept it. Path B is craft work; not racing competitors.
5. **The future-public option may never trigger.** Sleep-on-it acceptance: Alex builds Nous as if it stays his alone forever. The 3 hooks are insurance, not a promise.

## The fundamental fork (resolved)

Codex's framing question: **"Business that strangers pay for?" or "Alex's private thinking instrument?"**

Resolution: **Private thinking instrument.** Future business optionality preserved via 3 hooks but not committed.

This decision invalidates many sections of the original spec draft. They are listed in "What's CUT" above. The pivot is documented; the project commits to Path B.

## Decisions log

- **2026-04-27 morning** — Original Skill Fold spec drafted with mixed posture (single-user scope but multi-user readiness language).
- **2026-04-27 afternoon** — Codex challenge run. Identified mixed posture as polish-forever trap. Top 3 killers: timeline fantasy, polish-forever, weak moat claim.
- **2026-04-27 evening** — Alex chose Path B (private instrument, future-public optional). Spec rewritten.
- **Future** — Hooks remain in design. Multi-user pretense removed.

## Source files

- `docs/superpowers/specs/2026-04-28-quick-modes-contract-redesign.md` — Quick mode contract (prior, still in scope for Phase 1)
- `docs/superpowers/specs/2026-04-27-quick-action-agents-phase1-ab-design.md` — Phase 1 A+B (in flight)
- `.context/codex-session-id` — Codex challenge session (resumable for follow-up)
- Original spec draft — preserved in git history (commit before this rewrite)

## Next concrete step

1. **Phase 1 (tool use + loop) ship + commit.** Currently mid-branch. Finish first.
2. **Solve financial runway before Phase 2.1 starts.** Confirm 5+ months of independent income is real before investing more time. If not, this spec waits.
3. **Phase 2.1 entry: write `YYYY-MM-DD-skill-store-schema-design.md`** — concrete schema doc with hooks 1+2 baked in.
4. **Phase 2.2: author the 10 seed skills.** Migrate from existing mode addenda + 3-5 explicit Alex-taste skills (Cantonese preference, no advice list, stoic mode invariants).
5. **Phase 2.3: dogfood 30 days.** Log subjective + concrete improvement evidence.
6. **Decision point (week 11): continue or revert.**
