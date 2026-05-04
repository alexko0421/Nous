# Hidden Product Cognitive Roles V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build three hidden product cognitive roles for Nous: Memory Curator, Context/Evidence Steward, and Connection Judge.

**Architecture:** These are not UI features and not `.codex/agents`. They are small deterministic Swift services wired into the existing memory, prompt-context, and Galaxy edge paths so Nous stores less junk, cites cleaner evidence, and draws fewer weak connections. V1 uses rule-based scoring and XCTest coverage before any LLM or background autonomy.

**Tech Stack:** Swift, XCTest, existing `MemoryProjectionService`, `TurnMemoryContextBuilder`, `GalaxyRelationJudge`, `GalaxyEdgeEngine`, `MemoryPersistenceDecision`, `MemoryEvidenceSnippet`, and `SearchResult`.

---

## Repo Execution Note

This repo defaults to one lead agent. Do not spawn subagents unless Alex explicitly asks for parallel agents. Use Beads before editing, follow the existing dirty worktree without reverting unrelated changes, and run scoped workflow checks before closing the bead.

Do not edit `Sources/Nous/Resources/anchor.md`. Do not add UI. Do not add `.codex/agents`. Do not add new third-party dependencies. Do not modify `project.yml` unless Xcode fails to pick up files from directory sources.

## Product Experience Contract

The three roles protect product feel at the places where Nous can otherwise become noisy:

- **Memory Curator:** protects long-term memory from temporary errands, hard opt-outs, and consent-bound sensitive material.
- **Context/Evidence Steward:** protects the answer prompt from stale or off-topic context that makes Nous answer the wrong conversation.
- **Connection Judge:** protects Galaxy from weak semantic edges that look clever but do not have real evidence.

Success is not "more agents." Success is a calmer Nous: fewer false memories, fewer stale-context answers, and fewer dubious Galaxy connections.

## File Structure

- Create `Sources/Nous/Models/ProductCognitiveRoleModels.swift` for shared role labels and decision value types.
- Create `Sources/Nous/Services/MemoryCurator.swift` for memory persistence assessment.
- Create `Sources/Nous/Services/ContextEvidenceSteward.swift` for prompt-context filtering.
- Create `Sources/Nous/Services/ConnectionJudge.swift` for final Galaxy relation gating.
- Modify `Sources/Nous/Services/MemoryProjectionService.swift` so the existing `memoryPersistenceDecision(messages:projectId:)` path uses `MemoryCurator`.
- Modify `Sources/Nous/Services/TurnMemoryContextBuilder.swift` so fetched citations, recent conversations, and bounded memory evidence pass through `ContextEvidenceSteward`.
- Modify `Sources/Nous/Services/GalaxyEdgeEngine.swift` so local and refined semantic edge writes pass through `ConnectionJudge`.
- Modify `Sources/Nous/Services/GraphEngine.swift` only if `GalaxyEdgeEngine` needs a constructor default for `ConnectionJudge`.
- Test with `Tests/NousTests/MemoryCuratorTests.swift`.
- Test with `Tests/NousTests/ContextEvidenceStewardTests.swift`.
- Test with `Tests/NousTests/ConnectionJudgeTests.swift`.
- Extend `Tests/NousTests/TurnMemoryContextBuilderTests.swift` only for integration coverage that cannot live in the new steward test.
- Extend `Tests/NousTests/GalaxyRelationJudgeTests.swift` only if a current relation-judge behavior must be preserved while adding the gate.

---

### Task 1: Shared Role Models

**Files:**
- Create: `Sources/Nous/Models/ProductCognitiveRoleModels.swift`
- Test through compile from: `Tests/NousTests/MemoryCuratorTests.swift`

- [ ] **Step 1: Write the first failing Memory Curator test**

Create `Tests/NousTests/MemoryCuratorTests.swift` with the first behavior that names the shared models:

```swift
import XCTest
@testable import Nous

final class MemoryCuratorTests: XCTestCase {
    func testHardOptOutSuppressesPersistence() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "呢段唔好記住，我只是想讲出来。",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.role, .memoryCurator)
        XCTAssertEqual(assessment.lifecycle, .rejected)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.hardOptOut))
        XCTAssertTrue(assessment.reason.contains("opt-out"))
    }
}
```

- [ ] **Step 2: Run the focused test and confirm RED**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/MemoryCuratorTests
```

Expected: fail because `MemoryCurator` and the role model types do not exist.

- [ ] **Step 3: Add shared model types**

Create `Sources/Nous/Models/ProductCognitiveRoleModels.swift`:

```swift
import Foundation

enum ProductCognitiveRole: String, Equatable {
    case memoryCurator = "memory_curator"
    case contextEvidenceSteward = "context_evidence_steward"
    case connectionJudge = "connection_judge"
}

enum MemoryCurationLifecycle: String, Equatable {
    case stable
    case ephemeral
    case rejected
    case consentRequired = "consent_required"
}

struct MemoryCurationAssessment: Equatable {
    let role: ProductCognitiveRole
    let lifecycle: MemoryCurationLifecycle
    let kind: MemoryKind?
    let persistenceDecision: MemoryPersistenceDecision
    let reason: String
}

enum ContextEvidenceDropReason: String, Equatable {
    case empty
    case offTopic = "off_topic"
    case staleWithoutOverlap = "stale_without_overlap"
    case duplicate
}

struct ContextEvidenceDrop: Equatable {
    let role: ProductCognitiveRole
    let label: String
    let reason: ContextEvidenceDropReason
}

struct ContextEvidenceAssessment: Equatable {
    let role: ProductCognitiveRole
    let keptLabels: [String]
    let drops: [ContextEvidenceDrop]
}

enum ConnectionJudgeDecision: String, Equatable {
    case accept
    case reject
    case defer
}

struct ConnectionJudgeAssessment: Equatable {
    let role: ProductCognitiveRole
    let decision: ConnectionJudgeDecision
    let reason: String
    let verdict: GalaxyRelationVerdict?
}
```

- [ ] **Step 4: Add the minimal Memory Curator shell**

Create `Sources/Nous/Services/MemoryCurator.swift`:

```swift
import Foundation

final class MemoryCurator {
    func assess(
        latestUserText: String?,
        boundaryLines: [String]
    ) -> MemoryCurationAssessment {
        if SafetyGuardrails.containsHardMemoryOptOut(latestUserText) {
            return MemoryCurationAssessment(
                role: .memoryCurator,
                lifecycle: .rejected,
                kind: nil,
                persistenceDecision: .suppress(.hardOptOut),
                reason: "hard opt-out"
            )
        }

        return MemoryCurationAssessment(
            role: .memoryCurator,
            lifecycle: .stable,
            kind: nil,
            persistenceDecision: .persist,
            reason: "stable enough for memory refresh"
        )
    }
}
```

- [ ] **Step 5: Run the focused test and confirm GREEN**

Run the same command from Step 2. Expected: `MemoryCuratorTests` passes.

---

### Task 2: Memory Curator Behavior and Integration

**Files:**
- Modify: `Tests/NousTests/MemoryCuratorTests.swift`
- Modify: `Sources/Nous/Services/MemoryCurator.swift`
- Modify: `Sources/Nous/Services/MemoryProjectionService.swift`
- Regression: `Tests/NousTests/UserMemoryServiceTests.swift`

- [ ] **Step 1: Add RED tests for the real memory boundary**

Append these tests to `MemoryCuratorTests`:

```swift
func testSensitiveMemoryRequiresConsentWhenBoundarySaysAskFirst() {
    let curator = MemoryCurator()

    let assessment = curator.assess(
        latestUserText: "I had a panic attack yesterday.",
        boundaryLines: ["敏感內容先問"]
    )

    XCTAssertEqual(assessment.lifecycle, .consentRequired)
    XCTAssertEqual(assessment.persistenceDecision, .suppress(.sensitiveConsentRequired))
}

func testTemporaryErrandDoesNotBecomeStableMemory() {
    let curator = MemoryCurator()

    let assessment = curator.assess(
        latestUserText: "tomorrow remind me to compare shoes after class",
        boundaryLines: []
    )

    XCTAssertEqual(assessment.lifecycle, .ephemeral)
    XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
    XCTAssertTrue(assessment.reason.contains("temporary"))
}

func testStablePreferencePersistsAsPreference() {
    let curator = MemoryCurator()

    let assessment = curator.assess(
        latestUserText: "Remember that I prefer concise implementation plans.",
        boundaryLines: []
    )

    XCTAssertEqual(assessment.lifecycle, .stable)
    XCTAssertEqual(assessment.kind, .preference)
    XCTAssertEqual(assessment.persistenceDecision, .persist)
}
```

Run the focused test. Expected: fail on temporary classification, sensitive consent, and preference kind until implemented.

- [ ] **Step 2: Implement deterministic curation rules**

Update `MemoryCurator.assess` with this rule order:

```swift
let normalized = Self.normalized(latestUserText)
if normalized.isEmpty { return rejected("empty latest user text", suppressionReason: .unspecified) }
if SafetyGuardrails.containsHardMemoryOptOut(normalized) { return rejected("hard opt-out", suppressionReason: .hardOptOut) }
if SafetyGuardrails.requiresConsentForSensitiveMemory(boundaryLines: boundaryLines),
   SafetyGuardrails.containsSensitiveMemory(normalized) {
    return consentRequired("sensitive memory needs consent")
}
if Self.looksTemporary(normalized) { return ephemeral("temporary instruction or short-lived errand") }
return stable(kind: Self.inferredKind(from: normalized), reason: "stable enough for memory refresh")
```

Use private helpers in the same file:

```swift
private func stable(kind: MemoryKind?, reason: String) -> MemoryCurationAssessment {
    MemoryCurationAssessment(
        role: .memoryCurator,
        lifecycle: .stable,
        kind: kind,
        persistenceDecision: .persist,
        reason: reason
    )
}

private func ephemeral(_ reason: String) -> MemoryCurationAssessment {
    MemoryCurationAssessment(
        role: .memoryCurator,
        lifecycle: .ephemeral,
        kind: .temporaryContext,
        persistenceDecision: .suppress(.unspecified),
        reason: reason
    )
}

private func rejected(_ reason: String, suppressionReason: MemorySuppressionReason) -> MemoryCurationAssessment {
    MemoryCurationAssessment(
        role: .memoryCurator,
        lifecycle: .rejected,
        kind: nil,
        persistenceDecision: .suppress(suppressionReason),
        reason: reason
    )
}

private func consentRequired(_ reason: String) -> MemoryCurationAssessment {
    MemoryCurationAssessment(
        role: .memoryCurator,
        lifecycle: .consentRequired,
        kind: nil,
        persistenceDecision: .suppress(.sensitiveConsentRequired),
        reason: reason
    )
}

private static func looksTemporary(_ text: String) -> Bool {
    let phrases = ["today", "tomorrow", "right now", "for now", "this week", "今日", "聽日", "听日", "而家", "暂时", "暫時"]
    return phrases.contains { text.contains($0) }
}

private static func inferredKind(from text: String) -> MemoryKind? {
    if text.contains("prefer") || text.contains("preference") || text.contains("鍾意") || text.contains("钟意") {
        return .preference
    }
    if text.contains("don't") || text.contains("do not") || text.contains("唔好") || text.contains("不要") {
        return .boundary
    }
    if text.contains("decided") || text.contains("decision") || text.contains("决定") || text.contains("決定") {
        return .decision
    }
    return nil
}

private static func normalized(_ text: String?) -> String {
    (text ?? "")
        .lowercased()
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
```

Keep helper constructors private so tests assert behavior, not implementation.

- [ ] **Step 3: Wire MemoryProjectionService through Memory Curator**

In `Sources/Nous/Services/MemoryProjectionService.swift`, replace the body of `memoryPersistenceDecision(messages:projectId:)` with:

```swift
guard let latestUserMessage = messages.reversed().first(where: { $0.role == .user }) else {
    return .persist
}

let latestContent = Self.stripQuoteBlocks(latestUserMessage.content)
let boundaries = currentMemoryBoundary(projectId: projectId)
return MemoryCurator()
    .assess(latestUserText: latestContent, boundaryLines: boundaries)
    .persistenceDecision
```

This preserves the existing public API used by `ChatViewModel.turnOutcomeFactory`.

- [ ] **Step 4: Verify Memory Curator GREEN and existing memory tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/MemoryCuratorTests -only-testing:NousTests/UserMemoryServiceTests
```

Expected: all selected tests pass. If an existing `UserMemoryServiceTests` expectation conflicts, keep the product boundary and update only the test assertion that now expects temporary messages to suppress persistence.

---

### Task 3: Context/Evidence Steward Behavior

**Files:**
- Create: `Tests/NousTests/ContextEvidenceStewardTests.swift`
- Create: `Sources/Nous/Services/ContextEvidenceSteward.swift`

- [ ] **Step 1: Write RED tests for context filtering**

Create `Tests/NousTests/ContextEvidenceStewardTests.swift`:

```swift
import XCTest
@testable import Nous

final class ContextEvidenceStewardTests: XCTestCase {
    func testDropsBlankMemoryEvidence() {
        let steward = ContextEvidenceSteward()
        let evidence = MemoryEvidenceSnippet(
            label: "global",
            sourceNodeId: UUID(),
            sourceTitle: "Empty",
            snippet: "   "
        )

        let result = steward.filterMemoryEvidence([evidence], promptQuery: "memory architecture")

        XCTAssertTrue(result.kept.isEmpty)
        XCTAssertEqual(result.assessment.drops.map(\.reason), [.empty])
    }

    func testKeepsEvidenceWithLexicalOverlap() {
        let steward = ContextEvidenceSteward()
        let evidence = MemoryEvidenceSnippet(
            label: "project",
            sourceNodeId: UUID(),
            sourceTitle: "Architecture",
            snippet: "Alex wants raw SQLite ownership for memory architecture."
        )

        let result = steward.filterMemoryEvidence([evidence], promptQuery: "memory architecture")

        XCTAssertEqual(result.kept, [evidence])
        XCTAssertEqual(result.assessment.keptLabels, ["project"])
    }

    func testDropsUnrelatedRecentConversation() {
        let steward = ContextEvidenceSteward()
        let recents = [(title: "Shoes", memory: "Alex compared Cloudmonster sizing after class.")]

        let result = steward.filterRecentConversations(
            recents,
            promptQuery: "explain compound and complex sentences"
        )

        XCTAssertTrue(result.kept.isEmpty)
        XCTAssertEqual(result.assessment.drops.map(\.reason), [.offTopic])
    }
}
```

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ContextEvidenceStewardTests
```

Expected: fail because `ContextEvidenceSteward` does not exist.

- [ ] **Step 2: Implement the steward as a deterministic filter**

Create `Sources/Nous/Services/ContextEvidenceSteward.swift`:

```swift
import Foundation

final class ContextEvidenceSteward {
    typealias RecentConversation = (title: String, memory: String)

    func filterMemoryEvidence(
        _ evidence: [MemoryEvidenceSnippet],
        promptQuery: String
    ) -> (kept: [MemoryEvidenceSnippet], assessment: ContextEvidenceAssessment) {
        var kept: [MemoryEvidenceSnippet] = []
        var drops: [ContextEvidenceDrop] = []

        for item in evidence {
            let label = item.label
            let text = "\(item.sourceTitle) \(item.snippet)"
            if Self.normalizedTokens(text).isEmpty {
                drops.append(ContextEvidenceDrop(role: .contextEvidenceSteward, label: label, reason: .empty))
            } else if Self.hasOverlap(text, promptQuery) {
                kept.append(item)
            } else {
                drops.append(ContextEvidenceDrop(role: .contextEvidenceSteward, label: label, reason: .offTopic))
            }
        }

        return (
            kept,
            ContextEvidenceAssessment(
                role: .contextEvidenceSteward,
                keptLabels: kept.map(\.label),
                drops: drops
            )
        )
    }

    func filterRecentConversations(
        _ conversations: [RecentConversation],
        promptQuery: String
    ) -> (kept: [RecentConversation], assessment: ContextEvidenceAssessment) {
        var kept: [RecentConversation] = []
        var drops: [ContextEvidenceDrop] = []

        for conversation in conversations {
            let label = conversation.title
            let text = "\(conversation.title) \(conversation.memory)"
            if Self.normalizedTokens(text).isEmpty {
                drops.append(ContextEvidenceDrop(role: .contextEvidenceSteward, label: label, reason: .empty))
            } else if Self.hasOverlap(text, promptQuery) {
                kept.append(conversation)
            } else {
                drops.append(ContextEvidenceDrop(role: .contextEvidenceSteward, label: label, reason: .offTopic))
            }
        }

        return (
            kept,
            ContextEvidenceAssessment(
                role: .contextEvidenceSteward,
                keptLabels: kept.map { $0.title },
                drops: drops
            )
        )
    }

    private static func hasOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedTokens(lhs)
        let right = normalizedTokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return !left.intersection(right).isEmpty
    }

    private static func normalizedTokens(_ text: String) -> Set<String> {
        let stopwords: Set<String> = ["the", "and", "for", "with", "this", "that", "after", "about", "alex"]
        return Set(
            text.lowercased()
                .components { !$0.isLetter && !$0.isNumber }
                .map { String($0) }
                .filter { $0.count >= 3 && !stopwords.contains($0) }
        )
    }
}
```

- [ ] **Step 3: Run the focused steward tests**

Run the command from Step 1. Expected: all `ContextEvidenceStewardTests` pass.

---

### Task 4: Context/Evidence Steward Integration

**Files:**
- Modify: `Sources/Nous/Services/TurnMemoryContextBuilder.swift`
- Modify: `Tests/NousTests/TurnMemoryContextBuilderTests.swift`

- [ ] **Step 1: Add RED integration coverage**

Add a test to `TurnMemoryContextBuilderTests`:

```swift
func testBuilderFiltersUnrelatedRecentConversationMemory() throws {
    let store = try NodeStore(path: ":memory:")
    let current = NousNode(type: .conversation, title: "Grammar question", content: "", updatedAt: Date(timeIntervalSince1970: 3_000))
    let unrelated = NousNode(type: .conversation, title: "Shoes", content: "", updatedAt: Date(timeIntervalSince1970: 2_000))
    try store.insertNode(current)
    try store.insertNode(unrelated)
    try store.insertMemoryEntry(memoryEntry(scope: .conversation, scopeRefId: unrelated.id, content: "- Alex compared Cloudmonster sizing after class."))

    let core = UserMemoryCore(nodeStore: store, llmServiceProvider: { nil })
    let builder = TurnMemoryContextBuilder(
        nodeStore: store,
        vectorStore: VectorStore(nodeStore: store),
        embeddingService: EmbeddingService(),
        memoryProjectionService: MemoryProjectionService(nodeStore: store),
        contradictionMemoryService: ContradictionMemoryService(core: core)
    )

    let context = try builder.build(
        retrievalQuery: "compound complex sentence",
        promptQuery: "explain compound and complex sentences",
        node: current,
        policy: .full,
        now: Date(timeIntervalSince1970: 4_000)
    )

    XCTAssertTrue(context.recentConversations.isEmpty)
}
```

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/TurnMemoryContextBuilderTests
```

Expected: fail because the builder still includes unrelated recent conversation memory.

- [ ] **Step 2: Wire the steward into TurnMemoryContextBuilder**

Add a stored property and defaulted initializer parameter:

```swift
private let contextEvidenceSteward: ContextEvidenceSteward
```

```swift
contextEvidenceSteward: ContextEvidenceSteward = ContextEvidenceSteward()
```

After fetching `citations`, `recentConversations`, and `memoryEvidence`, apply the steward before creating `TurnMemoryContext`:

```swift
let filteredRecentConversations = contextEvidenceSteward
    .filterRecentConversations(recentConversations, promptQuery: promptQuery)
    .kept
let filteredMemoryEvidence = contextEvidenceSteward
    .filterMemoryEvidence(memoryEvidence, promptQuery: promptQuery)
    .kept
```

Use `filteredRecentConversations` and `filteredMemoryEvidence` in the returned `TurnMemoryContext`. Leave citations unchanged in this task unless a focused citation test is added; citation ranking already has vector similarity and snippets.

- [ ] **Step 3: Run builder and steward tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ContextEvidenceStewardTests -only-testing:NousTests/TurnMemoryContextBuilderTests
```

Expected: selected tests pass.

---

### Task 5: Connection Judge Behavior

**Files:**
- Create: `Tests/NousTests/ConnectionJudgeTests.swift`
- Create: `Sources/Nous/Services/ConnectionJudge.swift`

- [ ] **Step 1: Write RED tests for Galaxy edge gating**

Create `Tests/NousTests/ConnectionJudgeTests.swift`:

```swift
import XCTest
@testable import Nous

final class ConnectionJudgeTests: XCTestCase {
    func testRejectsMissingVerdict() {
        let judge = ConnectionJudge()

        let assessment = judge.assess(
            source: NousNode(type: .note, title: "A"),
            target: NousNode(type: .note, title: "B"),
            similarity: 0.91,
            verdict: nil
        )

        XCTAssertEqual(assessment.role, .connectionJudge)
        XCTAssertEqual(assessment.decision, .reject)
        XCTAssertNil(assessment.verdict)
    }

    func testRejectsSelfConnection() {
        let judge = ConnectionJudge()
        let node = NousNode(type: .note, title: "Same")
        let verdict = GalaxyRelationVerdict(
            relationKind: .topicSimilarity,
            confidence: 0.9,
            explanation: "same topic",
            sourceEvidence: "same",
            targetEvidence: "same"
        )

        let assessment = judge.assess(source: node, target: node, similarity: 0.9, verdict: verdict)

        XCTAssertEqual(assessment.decision, .reject)
    }

    func testAcceptsAtomBackedRelation() {
        let judge = ConnectionJudge()
        let sourceAtomId = UUID()
        let targetAtomId = UUID()
        let verdict = GalaxyRelationVerdict(
            relationKind: .supports,
            confidence: 0.82,
            explanation: "A reason supports a decision.",
            sourceEvidence: "Alex chose raw SQLite for ownership.",
            targetEvidence: "The data layer decision requires explicit control.",
            sourceAtomId: sourceAtomId,
            targetAtomId: targetAtomId
        )

        let assessment = judge.assess(
            source: NousNode(type: .note, title: "Reason"),
            target: NousNode(type: .note, title: "Decision"),
            similarity: 0.3,
            verdict: verdict
        )

        XCTAssertEqual(assessment.decision, .accept)
        XCTAssertEqual(assessment.verdict, verdict)
    }

    func testDefersGenericHighSimilarityTopicRelation() {
        let judge = ConnectionJudge()
        let verdict = GalaxyRelationVerdict(
            relationKind: .topicSimilarity,
            confidence: 0.96,
            explanation: "这只是语义相似，不是强结论；需要更多证据才能判断真正关系。",
            sourceEvidence: "Alex plans to buy shoes tomorrow.",
            targetEvidence: "Alex bought something before."
        )

        let assessment = judge.assess(
            source: NousNode(type: .conversation, title: "Shoes"),
            target: NousNode(type: .note, title: "Shopping"),
            similarity: 0.96,
            verdict: verdict
        )

        XCTAssertEqual(assessment.decision, .defer)
    }
}
```

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ConnectionJudgeTests
```

Expected: fail because `ConnectionJudge` does not exist.

- [ ] **Step 2: Implement Connection Judge**

Create `Sources/Nous/Services/ConnectionJudge.swift`:

```swift
import Foundation

final class ConnectionJudge {
    func assess(
        source: NousNode,
        target: NousNode,
        similarity: Float,
        verdict: GalaxyRelationVerdict?
    ) -> ConnectionJudgeAssessment {
        guard let verdict else {
            return reject("missing relation verdict")
        }

        guard source.id != target.id else {
            return reject("self connection")
        }

        if verdict.sourceAtomId != nil || verdict.targetAtomId != nil {
            return accept(verdict, reason: "atom-backed relation")
        }

        if verdict.relationKind == .topicSimilarity,
           verdict.explanation.contains("只是语义相似") {
            return ConnectionJudgeAssessment(
                role: .connectionJudge,
                decision: .defer,
                reason: "generic topic similarity needs stronger evidence",
                verdict: nil
            )
        }

        let hasUsableEvidence = !verdict.sourceEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !verdict.targetEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasUsableEvidence else {
            return reject("missing evidence")
        }

        guard verdict.confidence >= 0.65 || similarity >= 0.86 else {
            return reject("low confidence")
        }

        return accept(verdict, reason: "specific evidence-backed relation")
    }

    private func accept(_ verdict: GalaxyRelationVerdict, reason: String) -> ConnectionJudgeAssessment {
        ConnectionJudgeAssessment(role: .connectionJudge, decision: .accept, reason: reason, verdict: verdict)
    }

    private func reject(_ reason: String) -> ConnectionJudgeAssessment {
        ConnectionJudgeAssessment(role: .connectionJudge, decision: .reject, reason: reason, verdict: nil)
    }
}
```

- [ ] **Step 3: Run the focused judge tests**

Run the command from Step 1. Expected: all `ConnectionJudgeTests` pass.

---

### Task 6: Connection Judge Integration

**Files:**
- Modify: `Sources/Nous/Services/GalaxyEdgeEngine.swift`
- Modify: `Sources/Nous/Services/GraphEngine.swift` only if constructor forwarding is needed
- Test: `Tests/NousTests/ConnectionJudgeTests.swift`
- Regression: `Tests/NousTests/GalaxyRelationJudgeTests.swift`

- [ ] **Step 1: Add the judge to GalaxyEdgeEngine**

Add a stored property:

```swift
private let connectionJudge: ConnectionJudge
```

Add a defaulted initializer parameter:

```swift
connectionJudge: ConnectionJudge = ConnectionJudge(),
```

Assign it in `init`.

- [ ] **Step 2: Gate local semantic edge writes**

In `generateSemanticEdges(for:threshold:)`, replace the direct verdict guard with:

```swift
let rawVerdict = relationJudge.judge(
    source: node,
    target: neighbor.node,
    similarity: neighbor.similarity,
    sourceAtoms: sourceAtoms,
    targetAtoms: atomsByNodeId[neighbor.node.id, default: []]
)
let assessment = connectionJudge.assess(
    source: node,
    target: neighbor.node,
    similarity: neighbor.similarity,
    verdict: rawVerdict
)
guard assessment.decision == .accept, let verdict = assessment.verdict else {
    continue
}
```

- [ ] **Step 3: Gate refined semantic edge writes**

Apply the same pattern in `refineSemanticEdge(sourceId:targetId:)` and `refineSemanticEdges(for:threshold:maxCandidates:)`. For `refineSemanticEdge`, if the raw refined verdict is nil or the connection judge does not accept it, keep the existing behavior that deletes the weak semantic edge and returns nil.

- [ ] **Step 4: Run Galaxy relation regressions**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ConnectionJudgeTests -only-testing:NousTests/GalaxyRelationJudgeTests
```

Expected: selected tests pass. If a `GalaxyRelationJudgeTests` case expects a generic topic-similarity verdict from the judge itself, keep that test unchanged; Connection Judge is the edge-writing gate, not a replacement for relation judging.

---

### Task 7: Final Verification and Workflow Check

**Files:**
- All files created or modified by Tasks 1-6

- [ ] **Step 1: Run focused tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/MemoryCuratorTests -only-testing:NousTests/ContextEvidenceStewardTests -only-testing:NousTests/ConnectionJudgeTests -only-testing:NousTests/TurnMemoryContextBuilderTests -only-testing:NousTests/GalaxyRelationJudgeTests
```

Expected: all selected tests pass.

- [ ] **Step 2: Run the full Nous test suite if focused tests are green**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS'
```

Expected: pass. If the full suite is too slow or blocked by unrelated dirty worktree changes, record the exact blocker and keep the focused test output as the acceptance gate.

- [ ] **Step 3: Run scoped workflow check before finishing the bead**

Replace `<bead-id>` with the active implementation bead:

```bash
scripts/agentic_workflow_check.sh --bead <bead-id> \
  --path Sources/Nous/Models/ProductCognitiveRoleModels.swift \
  --path Sources/Nous/Services/MemoryCurator.swift \
  --path Sources/Nous/Services/ContextEvidenceSteward.swift \
  --path Sources/Nous/Services/ConnectionJudge.swift \
  --path Sources/Nous/Services/MemoryProjectionService.swift \
  --path Sources/Nous/Services/TurnMemoryContextBuilder.swift \
  --path Sources/Nous/Services/GalaxyEdgeEngine.swift \
  --path Sources/Nous/Services/GraphEngine.swift \
  --path Tests/NousTests/MemoryCuratorTests.swift \
  --path Tests/NousTests/ContextEvidenceStewardTests.swift \
  --path Tests/NousTests/ConnectionJudgeTests.swift \
  --path Tests/NousTests/TurnMemoryContextBuilderTests.swift
```

Expected: OK, or a scoped warning that names only unrelated dirty files outside this implementation.

## Self-Review

- Spec coverage: the plan covers all three hidden roles and maps each one to the existing product path it protects.
- Scope: no UI, no `.codex/agents`, no `anchor.md`, no new dependencies, no broad architecture rewrite.
- TDD: every new role starts with a focused failing test before production code.
- Usability: a future agent can answer where each role lives, what tests prove it, and how it integrates.
- Risk: Context filtering can become too aggressive. The first integration filters recent conversation memory and bounded memory evidence only; citation filtering is deferred until a focused citation test exists.
