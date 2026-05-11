# Memory Recall Reliability — Cross-Conversation Cross-Lingual Foundation

> Status: Spec, pending writing-plans → executing-plans. Class-anchored, not incident-anchored.
> Supersedes the 2026-05-08-anchored scope of `docs/superpowers/plans/2026-05-08-memory-retrieval-multilingual-architecture.md` for Alex's primary日常 chat flow (does NOT replace that plan for chat-citation chips / source-chunk retrieval).

## Anchoring体感

Alex's lived complaint (2026-05-10): "memory 系一时得一时唔得". When current message thematically relates to past content, Nous sometimes brings the past content up, sometimes doesn't, with no obvious pattern. This spec treats that体感 as the goal, not any specific historical incident.

## Diagnosis (today, from production DB trace)

Five class-level failures stack to produce the体感. Three are in scope here; two are out.

**In scope:**

1. **Atom extraction translates Cantonese → English at write time.** `MemoryGraphAtomMapper` / atom extractor prompt produces statements like `"I made it to the US at all is already remarkable"` from Alex's Cantonese「我嚟到美国都已经系不可思议嘅啦」. Original voice is gone before retrieval ever sees the row.

2. **Embedding model is English-only.** `EmbeddingService.defaultModelId = "sentence-transformers/all-MiniLM-L6-v2"`. `LexicalIndex.swift:9` and `MemoryQueryPlanner.swift:675` already document this as a known problem. Cantonese queries against English atoms land in the cosine noise zone.

3. **Default chat doesn't query atoms at all.** `PromptContextAssembler.swift:1188` gates `CitableContextBuilder` behind `activeQuickActionMode != nil`. Default chat instead reads `MemoryProjectionService` → static conversation-scoped `memory_entries` blob. The blob is identical regardless of what Alex just typed, and zero global / project `memory_entries` rows exist (verified in production DB).

**Out of scope (deferred / separate path):**

4. ~~`messages_fts` / `nodes_fts` trigram tokenizer for chat-citation chips.~~ The 2026-05-08 incident scope. Alex's体感 is about atom-level recall in default chat, not the citation chips that Move 1 of the older plan targets.

5. ~~Cross-conversation `memory_entries` aggregation.~~ Redundant if Block 4b routes default chat through `CitableContextBuilder`, which already does cross-conversation atom retrieval.

## Why class-anchored, not incident-anchored

Earlier scoping (2026-05-08 forensic trace) anchored everything on one screenshot: roommate query → Kai Trump appearing instead of 室友 chat. That incident has already passed in Alex's lived experience. Locking the system's regression baseline to that specific event over-fits to history and conflates "fix this one chat-citation surface" with the broader recall reliability problem.

This spec treats the diagnosis layers as classes of failure and tests them with synthetic fixture data (dummy chat titles like `chat-A`, `chat-B`), not with names from any historical incident.

## Approach: C, refined

Three structural changes, deferred backfill, class-level fixture. Total estimate: 2.5–3 working days.

### Change 1 — Multilingual embedding model + signature column

**Mechanism:** Replace `all-MiniLM-L6-v2` with a multilingual sentence-transformer. Two candidates, locked by quick verification in Phase 0:

- `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2` — 384 dim, drop-in BERT-base family, mean pooling. Preferred default.
- `intfloat/multilingual-e5-small` — 384 dim, requires `query:` / `passage:` instruction prefix. Backup if MLXEmbedders compat issue.

**Schema:** Add `embedding_signature TEXT NOT NULL` to `memory_atoms`, `nodes`, `source_chunks`. Format: `<model_id_short>-<dim>-<pooling>-<norm>-<prefix_version>`. Single source of truth: `EmbeddingService.currentSignature`. Vector search rejects cross-signature comparison at the query layer.

**Migration:** `EmbeddingMigrationRunner` re-embeds all rows with the new signature. Idempotent, resumable, with these failure semantics:
- App restart mid-migration → resume from last committed batch.
- Partial batch failure → log + skip + retry next run.
- Corrupted blob → mark `embedding_signature='migration_failed'`, surface in HarnessHealth.
- Model download failure → abort, old rows untouched, old signature still active.

**Why this layer first:** Without multilingual embedding, every other fix is upstream of a broken search. Atom extractor保留 Cantonese is useless if Cantonese atom embeddings are noise.

**Estimate:** ~1.5 days.

### Change 2 — Atom extractor preserves verbatim Cantonese

**Mechanism:** Modify the atom-extraction prompt in `AtomExtractor` / `MemoryGraphAtomMapper` to (a) keep `statement` in the original language Alex spoke, and (b) add an optional `verbatimQuote` field carrying the exact substring from the source message that the atom is rooted in.

**Concrete before/after** (using a real atom from production):

```
Source message (Alex, 2026-05-10 00:52):
「再加上其实我唔系一个读书好叻嘅人啦,咁,我觉得,我嚟到美国都已经系不可思议嘅啦」

Current atom (English):
type: belief
statement: "I am not academically strong, and just getting to the US is already remarkable for someone like me"

New atom (preserves voice):
type: belief
statement: "我唔系一个读书好叻嘅人,嚟到美国都已经系不可思议"
verbatimQuote: "我唔系一个读书好叻嘅人啦...我嚟到美国都已经系不可思议嘅啦"
```

**Migration impact on existing atoms:** None mandatory. Old English atoms continue to live; new Cantonese atoms accumulate alongside. Both are retrievable via multilingual embedding (Change 1). Backfill is **deferred**, decision below.

**Estimate:** ~half day. Prompt change + atom model schema update + tests on prompt output shape.

### Change 3 — Block 4b flag flip: default chat through CitableContextBuilder

**Mechanism:** Remove the `activeQuickActionMode != nil` gate at `PromptContextAssembler.swift:1188`. Default chat path calls `CitableContextBuilder.build()` (which it already does for quick-action modes), getting query-driven atom retrieval with `MemoryQueryPlanner` (intent planner) + `LexicalIndex.searchMemoryAtoms` (FTS5 trigram) + multilingual vector lane (Change 1).

**Migration of static `memory_entries` blob:** `MemoryProjectionService.currentConversation/Project/Global` becomes a fallback for the thread-summary use case only (recent conversation summary remains useful for orientation). Cross-conversation recall is entirely through atoms.

**Concrete before/after** for Alex's evening conversation (2026-05-10 19:30):

```
Current (default chat path):
  Global memory:        ""  (no rows)
  Project memory:       ""  (no rows)
  Conversation memory:  [1103-char thread summary of current 普通人 podcast convo]
  → Total memory context: ~1100 chars, conversation-local only.
  → Alex's 00:52 自卑 conversation: invisible.

After Change 3 (default chat via CitableContextBuilder):
  CitableContextBuilder query: <last user message>
  Planner intent: emotional-recall + self-positioning
  Atom hits across conversations:
    - 8DA1A295 (00:52 today): "Self-inferiority is recurring for me..."
    - 8DA1A295 (00:52 today): "I want a second measuring stick beyond academic comparison"
    - AA47EB80 (current convo): "Each ordinary person's story 不比 successful people 逊色"
    - AA47EB80 (current convo): "Listening to ordinary people = material for periodic self-upgrades"
  + ConversationSummary (kept for thread orientation): 1103-char blob
  → Cross-conversation recall: live.
```

**Estimate:** ~half day. Gate removal + ensure `MemoryQueryPlanner` runs in default chat path + retain conversation summary as orientation block.

## Deferred decision: backfill of 1810 existing atoms

**Default: do not backfill.** Re-extracting 1810 atoms costs LLM tokens and time. New Cantonese atoms accumulate during normal use; within 2–4 weeks they meaningfully overtake the old English-only set. Combined with multilingual embedding (Change 1), old English atoms remain retrievable in the same vector space as new Cantonese atoms.

**Re-evaluation gate:** After Change 1+2+3 ships, observe 2 weeks. If体感 still shows "Nous forgets things I said over a week ago" with specific examples, then evaluate targeted backfill (e.g., last 30 days only, prioritized by atom confidence). Decision lives in `MEMORY.md` under `project_memory_recall_backfill_evaluation`.

## Class-level fixture (replaces 2026-05-08 incident fixture)

`Tests/NousTests/MemoryRecallReliabilityTests.swift` — synthetic fixture corpus, no historical instance names.

**Fixture corpus (~12 dummy nodes, locked):**
- 4 Cantonese-only chats with synthetic titles `chat-A` … `chat-D`, each with 2–4 messages on distinct topics.
- 3 Mandarin-only chats `chat-E` … `chat-G`.
- 2 code-switch chats `chat-H`, `chat-I`.
- 3 English-only chats `chat-J`, `chat-K`, `chat-L`.
- Atoms extracted per fixture chat using the new prompt (Change 2), embedded with the new model (Change 1).

**Class assertions (test the mechanism, not specific names):**

| # | Class assertion |
|---|---|
| 1 | Any Cantonese query containing a 2-char keyword that appears verbatim in a fixture chat's atoms → that chat's atoms appear in top-K results |
| 2 | Code-switch Cantonese-English query → atoms from both same-topic Cantonese and English chats appear |
| 3 | Cantonese query whose topic semantically matches English-only fixture atom → English atom retrievable via vector lane (cross-lingual semantic) |
| 4 | Off-topic query (no fixture atom matches) → empty result OR low-confidence flag, no false positive |
| 5 | Default-chat path with `activeQuickActionMode == nil` → CitableContextBuilder still runs, atoms surface (Change 3 contract) |
| 6 | Atom written by new extractor → `statement` is in source-message language, `verbatimQuote` non-empty (Change 2 contract) |
| 7 | Cross-signature query rejected → vector search comparing rows with mismatched `embedding_signature` returns 0 or errors loudly (Change 1 contract) |

**Discipline:** Unit tests use `FakeEmbeddingService` with deterministic vectors so mechanism-level assertions don't depend on real model behavior. A separate integration suite (env-gated `MEMORY_RECALL_INTEGRATION=1`) runs the real model on the same fixture for quality validation, manually triggered before merge.

## Constraints

- Do not modify `Sources/Nous/Resources/anchor.md` (frozen per `AGENTS.md:39, 131`).
- No new third-party dependencies. `MLXEmbedders` is the embedding runtime.
- Build via `xcodebuild`, not `swift build` (per project memory `project_nous_build_tool`).
- Re-embedding is acceptable. Migration runner must handle full failure semantics enumerated in Change 1.
- The block-4b feature flag flip (Change 3) must not regress quick-action mode behavior — same path, same builder, same policy.
- Cross-conversation recall via `CitableContextBuilder` must respect `QuickActionMemoryPolicy` quotas (extending defaults for default chat as needed).

## Explicit non-goals

- Chat-citation chips visual / surface area (separate plan, 2026-05-08).
- Source-chunk retrieval beyond what `CitableContextBuilder` already does.
- Memory aging / decay policy (separate concern, future spec).
- Reflection prompt redesign (corpus-scope rule + Gemini-vs-Sonnet routing is its own decision).
- UI changes for citation provenance display.
- Backfill of 1810 existing atoms — deferred, see decision section.

## Phasing

```
Phase 0 (~½ day): MLXEmbedders compat check on both candidate multilingual models
  - Verify tokenizer, pooling, normalization, instruction prefix support
  - Latency + memory footprint on M-series
  - Lock model choice

Phase 1 (~1.5 days): Change 1 — multilingual embedding + signature + migration runner
  - Schema migration
  - EmbeddingService.currentSignature wired
  - EmbeddingMigrationRunner with failure semantics
  - Re-embed corpus
  - Fixture assertions 1, 3, 4, 7 pass

Phase 2 (~½ day): Change 2 — atom extractor保留 Cantonese
  - Prompt change
  - Atom model schema (verbatimQuote field)
  - Fixture assertion 6 passes
  - New atoms in production start carrying voice

Phase 3 (~½ day): Change 3 — Block 4b flag flip
  - Remove activeQuickActionMode gate in PromptContextAssembler:1188
  - Ensure MemoryQueryPlanner runs in default chat
  - Retain conversation summary as orientation block
  - Fixture assertion 5 passes
  - Live体感 validation: open production app, test cross-conversation recall in Cantonese
```

## Open questions

1. **Default-chat quotas.** What `QuickActionMemoryPolicy.citationChatQuota` / `sourceQuota` defaults apply when `activeQuickActionMode == nil`? Propose: `chat=4, source=1` (recall-heavy, since default chat is the discovery surface, not the research surface).
2. **Conversation summary placement.** When Change 3 ships, does the existing `memory_entries` conversation summary stay in the prompt alongside `CitableContextBuilder` output, or get dropped? Propose: keep, with explicit `<thread-orientation>` block wrapping it, so it's recognized as orientation context not authoritative memory.
3. **Migration UI.** Does the embedding migration need a user-visible progress UI, or can it run silently on app launch? For Alex-only product, silent + log to HarnessHealth is probably sufficient.
4. **Atom backfill telemetry.** What signal triggers re-evaluation of the deferred backfill decision? Propose: log per-turn `cross_conversation_atom_hits_count` and review weekly.

## What this spec does not commit to

- A specific multilingual embedding model (Phase 0 locks it).
- A specific atom prompt format (Phase 2 designs it; constraint is `statement` in source language + non-empty `verbatimQuote`).
- A specific fixture seed corpus content (Phase 0 generates synthetic Cantonese / Mandarin / English / code-switch text; locks once).
- Whether to backfill old atoms (deferred decision after 2-week observation).
