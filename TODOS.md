
## From /plan-eng-review (WeeklyReflectionService) — 2026-04-22

- [ ] **Migrate ProvocationJudge to native Gemini `responseSchema`**
  - **What:** Replace regex `extractJSONObject()` in ProvocationJudge.swift:61 with Gemini native structured output (the same responseSchema path added to GeminiLLMService for WeeklyReflectionService).
  - **Why:** Eliminates shape-level JSON parse fragility. ProvocationJudge has hit `JudgeError.badJSON` in the past when flash prepends code fences or explanatory prose.
  - **Pros:** One retrieval path failure mode removed; consistent structured-output pattern across services.
  - **Cons:** Requires JudgeVerdict → JSON schema definition; regression risk on existing judge tests.
  - **Context:** Out-of-scope for the WeeklyReflectionService PR (A4 decision). Revisit after W4 evaluation of reflection quality — if native path proves reliable on new service, migrate judge next.
  - **Depends on:** WeeklyReflectionService shipped and W4 evaluation memo written.

- [ ] **Audit NodeStore.deleteNode cascade atomicity**
  - **What:** Verify `NodeStore.deleteNode(...)` wraps `DELETE FROM nodes` + cascade-triggered deletes + any orphan-status updates in a single SQLite transaction (`BEGIN ... COMMIT`). Add wrap if missing.
  - **Why:** Critical gap flagged in eng review. If app is killed mid-cascade, SQLite WAL should rollback — but only if the whole operation is one transaction. If orphan-status update on `reflection_claim` sits outside the transaction that deletes messages, half-orphan state is possible.
  - **Pros:** Closes a silent-failure class (hallucinated reflections referencing deleted turns).
  - **Cons:** Minor — may require restructuring `deleteNode` signature if currently split across methods.
  - **Context:** Discovered during WeeklyReflectionService eng review. Applies to any future cascade user (not specific to reflections). Start at `Sources/Nous/Services/NodeStore.swift:deleteNode` — check for `BEGIN TRANSACTION` / `try db.transaction { ... }` wrapping.
  - **Depends on:** WeeklyReflectionService schema landed (so orphan-status update exists and needs to be in the transaction).

- [ ] **Timezone handling for weekly reflection boundary**
  - **What:** Define canonical "Sunday 23:00" boundary using a fixed timezone (e.g., user's primary tz stored in Settings) rather than `Calendar.current` which shifts when user travels.
  - **Why:** Cross-timezone travel (e.g., Alex flies HK→SF) could cause the cursor check to misfire — either double-run a week or skip a week. Uncommon but silent when it happens.
  - **Pros:** Deterministic week boundaries; eval logs remain comparable across weeks.
  - **Cons:** Requires a "primary timezone" setting. For v1 Alex-only audience, can default to Asia/Hong_Kong without UI.
  - **Context:** For v1, hardcode Asia/Hong_Kong or use the device timezone snapshotted at Nous install time. For v2 when audience grows, add Settings entry.
  - **Depends on:** WeeklyReflectionService shipped with `Calendar.current` default (acceptable for Alex-at-home baseline).

## From /plan-eng-review (Codex second pass) — 2026-04-22

- [ ] **W1 D1 spike: verify Gemini `responseSchema` API shape (first 30 min)**
  - **What:** Before committing to `GeminiLLMService.responseSchema` extension, hit the Gemini API with a minimal responseSchema request and confirm the exact JSON shape of `generationConfig.responseSchema`.
  - **Why:** A4 decision assumed the extension is ~10 lines. If the actual API shape differs from the sketch (e.g., needs `responseMimeType`, nested typing syntax, field ordering), the extension is larger and changes W1 D2 effort.
  - **Pros:** De-risks W1 D2. Catches shape drift before any Swift is written.
  - **Cons:** None. 30 min on Day 1 beats rework on Day 2.
  - **Depends on:** Nothing. This is the first W1 D1 task.

- [ ] **App-level orphan update, not just FK cascade**
  - **What:** When `messages` row is deleted (cascade fires on `reflection_evidence`), explicitly transition parent `reflection_claim.status` to `'orphaned'` if remaining evidence count < 2. Wrap the cascade + orphan-update in a single transaction via `NodeStore.swift:494` transaction primitive.
  - **Why:** FK cascade alone only deletes evidence rows. The parent claim keeps `status='active'` with zero evidence, which is a silent data-integrity break — claim still returns from retrieval query, fails validator on next citation, user sees "wait, that reflection has nothing behind it."
  - **Pros:** Preserves Premise #4 (traceability as hard invariant). Closes a silent-failure class.
  - **Cons:** Adds transaction complexity to node-delete path.
  - **Depends on:** WeeklyReflectionService schema landed.

- [ ] **UNIQUE(week_start, week_end, project_id) on reflection_runs**
  - **What:** Add UNIQUE constraint on `reflection_runs(week_start, week_end, project_id)`. Use INSERT OR REPLACE with explicit retry semantics.
  - **Why:** Foreground-rollover trigger + (future) background trigger + retry-after-partial-failure can all double-write for the same week. Without UNIQUE, two runs = two sets of claims = retrieval picks the newer but older-claim rows linger.
  - **Pros:** Idempotent weekly runs. Safe to retry.
  - **Cons:** None.
  - **Depends on:** Included in W1 D1 schema migration (R3).

- [ ] **Extend MemoryDebugInspector with reflections tab**
  - **What:** Add a reflections view to `MemoryDebugInspector` showing run metadata, claim list, confidence scores, evidence-chatmessage links, orphan-status flags.
  - **Why:** Currently no way to inspect a written reflection without raw SQL. Blocks the Month 1 evaluation memo workflow — Alex will be hand-writing SQL queries every Monday if this doesn't exist.
  - **Pros:** Unblocks eval loop. Connects to existing thinking-accordion thesis ("make cognition visible").
  - **Cons:** Minor UI work, tied to existing inspector.
  - **Depends on:** WeeklyReflectionService schema landed + first reflection run written.

- [ ] **Transaction wrap for reflection run write**
  - **What:** Wrap `reflection_runs` row write + N `reflection_claim` rows + M `reflection_evidence` rows in a single transaction via `NodeStore.swift:494` primitive.
  - **Why:** Half-written runs (crash between claim write and evidence write) leave the DB in a poisoned state — claim rows exist but point to no evidence, retrieval includes them, validator rejects at citation time, silent breakage.
  - **Pros:** All-or-nothing semantics for weekly runs. Paired with T3 UNIQUE + T2 orphan-update, gives full data-integrity contract.
  - **Cons:** None.
  - **Depends on:** W1 D2 `WeeklyReflectionService` implementation.
