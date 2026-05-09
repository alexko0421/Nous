# Cognition Director V2 Trace-First Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a trace-first `CognitionDirector` that records one safe per-turn cognition frame without changing answer behavior.

**Architecture:** Extend existing cognition contracts and `TurnCognitionSnapshot` with a legacy-compatible optional `CognitionFrame`. Add a pure `CognitionDirector` collector that reads already-computed `TurnPlan`, commit, and review state. Wire it through `TurnCognitionSnapshotFactory` and summarize it in `TurnCognitionInspectorFeed`.

**Tech Stack:** Swift, XCTest, existing `TurnPlan`, `TurnCognitionSnapshot`, `PromptGovernanceTrace`, `GovernanceTelemetryStore`, and `TurnCognitionInspectorFeed`.

---

## File Structure

- Modify `Sources/Nous/Models/Cognition/CognitionContracts.swift`: add frame/record contracts and optional frame on `TurnCognitionSnapshot`.
- Create `Sources/Nous/Services/CognitionDirector.swift`: pure frame collector.
- Modify `Sources/Nous/Services/ChatTurnRunner.swift`: have `TurnCognitionSnapshotFactory` attach a frame.
- Modify `Sources/Nous/Services/TurnCognitionInspectorFeed.swift`: summarize organ participation.
- Modify `Tests/NousTests/CognitionContractsTests.swift`: contract, privacy, and legacy decode tests.
- Create `Tests/NousTests/CognitionDirectorTests.swift`: frame collector behavior tests.
- Modify `Tests/NousTests/TurnCognitionInspectorFeedTests.swift`: feed summary coverage.

---

### Task 1: Contracts And Legacy Snapshot Decode

**Files:**
- Modify: `Sources/Nous/Models/Cognition/CognitionContracts.swift`
- Modify: `Tests/NousTests/CognitionContractsTests.swift`

- [ ] **Step 1: Write failing contract tests**

Append tests to `Tests/NousTests/CognitionContractsTests.swift`:

```swift
func testCognitionFrameValidatesRecordsWithoutRawPromptText() throws {
    let frame = CognitionFrame(
        turnId: UUID(),
        conversationId: UUID(),
        assistantMessageId: UUID(),
        records: [
            CognitionOrganRecord(
                organ: .coordinator,
                label: "turn_steward",
                status: .used,
                reason: "ordinary_chat_full_memory",
                evidenceRefs: [],
                resourceIds: ["skill:00000000-0000-0000-0000-000000000001"],
                riskFlags: []
            )
        ],
        createdAt: Date(timeIntervalSince1970: 100)
    )

    XCTAssertNoThrow(try frame.validated())
    let encoded = String(data: try JSONEncoder().encode(frame), encoding: .utf8)!
    XCTAssertFalse(encoded.contains("Help me plan"))
    XCTAssertFalse(encoded.contains("Assistant draft"))
}

func testCognitionFrameRejectsBlankRecordLabel() {
    let frame = CognitionFrame(
        turnId: UUID(),
        conversationId: UUID(),
        assistantMessageId: nil,
        records: [
            CognitionOrganRecord(
                organ: .coordinator,
                label: "   ",
                status: .used,
                reason: "ordinary_chat",
                evidenceRefs: [],
                resourceIds: [],
                riskFlags: []
            )
        ]
    )

    XCTAssertThrowsError(try frame.validated()) { error in
        XCTAssertEqual(error as? CognitionValidationError, .emptySummary)
    }
}

func testLegacyTurnCognitionSnapshotDecodesWithoutCognitionFrame() throws {
    let json = """
    {
      "turnId": "00000000-0000-0000-0000-000000000101",
      "conversationId": "00000000-0000-0000-0000-000000000102",
      "assistantMessageId": "00000000-0000-0000-0000-000000000103",
      "promptLayers": ["anchor", "chat_mode"],
      "slowCognitionAttached": false,
      "reviewArtifactId": null,
      "reviewRiskFlags": [],
      "reviewConfidence": null,
      "recordedAt": 1000
    }
    """.data(using: .utf8)!

    let snapshot = try JSONDecoder().decode(TurnCognitionSnapshot.self, from: json)

    XCTAssertNil(snapshot.cognitionFrame)
    XCTAssertEqual(snapshot.promptLayers, ["anchor", "chat_mode"])
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/CognitionContractsTests/testCognitionFrameValidatesRecordsWithoutRawPromptText -only-testing:NousTests/CognitionContractsTests/testCognitionFrameRejectsBlankRecordLabel -only-testing:NousTests/CognitionContractsTests/testLegacyTurnCognitionSnapshotDecodesWithoutCognitionFrame CODE_SIGNING_ALLOWED=NO
```

Expected: compile fails because `CognitionFrame`, `CognitionOrganRecord`, `CognitionOrganStatus`, and `snapshot.cognitionFrame` do not exist.

- [ ] **Step 3: Add contracts**

Add to `Sources/Nous/Models/Cognition/CognitionContracts.swift` after `CognitionTrace`:

```swift
enum CognitionOrganStatus: String, Codable, Equatable, Sendable {
    case used
    case skipped
    case failed
}

struct CognitionOrganRecord: Codable, Equatable, Sendable {
    let organ: CognitionOrgan
    let label: String
    let status: CognitionOrganStatus
    let reason: String
    let evidenceRefs: [CognitionEvidenceRef]
    let resourceIds: [String]
    let riskFlags: [String]

    init(
        organ: CognitionOrgan,
        label: String,
        status: CognitionOrganStatus,
        reason: String,
        evidenceRefs: [CognitionEvidenceRef] = [],
        resourceIds: [String] = [],
        riskFlags: [String] = []
    ) {
        self.organ = organ
        self.label = label
        self.status = status
        self.reason = reason
        self.evidenceRefs = evidenceRefs
        self.resourceIds = resourceIds
        self.riskFlags = riskFlags
    }

    @discardableResult
    func validated() throws -> CognitionOrganRecord {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CognitionValidationError.emptySummary
        }
        guard evidenceRefs.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CognitionValidationError.invalidEvidenceRef
        }
        return self
    }
}

struct CognitionFrame: Codable, Equatable, Identifiable, Sendable {
    static let currentVersion = 1

    let id: UUID
    let turnId: UUID
    let conversationId: UUID
    let assistantMessageId: UUID?
    let frameVersion: Int
    let records: [CognitionOrganRecord]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        turnId: UUID,
        conversationId: UUID,
        assistantMessageId: UUID?,
        frameVersion: Int = Self.currentVersion,
        records: [CognitionOrganRecord],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.turnId = turnId
        self.conversationId = conversationId
        self.assistantMessageId = assistantMessageId
        self.frameVersion = frameVersion
        self.records = records
        self.createdAt = createdAt
    }

    @discardableResult
    func validated() throws -> CognitionFrame {
        guard frameVersion > 0 else { throw CognitionValidationError.invalidBudget }
        try records.forEach { try $0.validated() }
        return self
    }
}
```

Extend `TurnCognitionSnapshot` with `let cognitionFrame: CognitionFrame?`, add an optional init parameter defaulting to `nil`, add it to `CodingKeys`, and decode with:

```swift
cognitionFrame = try container.decodeIfPresent(CognitionFrame.self, forKey: .cognitionFrame)
```

- [ ] **Step 4: Verify GREEN**

Run the focused command from Step 2. Expected: all three tests pass.

---

### Task 2: Pure Cognition Director Collector

**Files:**
- Create: `Sources/Nous/Services/CognitionDirector.swift`
- Create: `Tests/NousTests/CognitionDirectorTests.swift`

- [ ] **Step 1: Write failing director tests**

Create `Tests/NousTests/CognitionDirectorTests.swift`:

```swift
import XCTest
@testable import Nous

final class CognitionDirectorTests: XCTestCase {
    func testFrameRecordsUsedAndSkippedOrgansWithoutPromptText() throws {
        let turnId = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let conversationId = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let assistantId = UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
        let skillId = UUID(uuidString: "00000000-0000-0000-0000-000000000204")!
        let evidenceId = UUID(uuidString: "00000000-0000-0000-0000-000000000205")!
        let citationId = UUID(uuidString: "00000000-0000-0000-0000-000000000206")!

        let plan = makePlan(
            turnId: turnId,
            conversationId: conversationId,
            promptTrace: PromptGovernanceTrace(
                promptLayers: ["anchor", "memory_evidence", "slow_cognition"],
                evidenceAttached: true,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: false,
                turnSteward: TurnStewardTrace(
                    route: .ordinaryChat,
                    memoryPolicy: .full,
                    challengeStance: .surfaceTension,
                    responseShape: .answerNow,
                    projectSignalKind: nil,
                    source: .deterministic,
                    reason: "analysis skill cue"
                ),
                agentCoordination: AgentCoordinationTrace(
                    executionMode: .toolLoop,
                    quickActionMode: .plan,
                    provider: .claude,
                    reason: .explicitQuickActionToolLoop,
                    indexedSkillCount: 1
                ),
                slowCognitionTrace: SlowCognitionPromptTrace(
                    artifact: CognitionArtifact(
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000207")!,
                        organ: .patternAnalyst,
                        title: "Weekly pattern",
                        summary: "A safe summary.",
                        confidence: 0.8,
                        jurisdiction: .selfReflection,
                        evidenceRefs: [CognitionEvidenceRef(source: .message, id: evidenceId.uuidString)]
                    )
                )
            ),
            judgeFallback: .ok,
            indexedSkillIds: [skillId],
            loadedSkillIds: [skillId],
            memoryEvidenceSourceIds: [evidenceId],
            loadedCitationIds: [citationId]
        )
        let committed = CommittedAssistantTurn(
            node: plan.prepared.node,
            assistantMessage: Message(id: assistantId, nodeId: conversationId, role: .assistant, content: "Assistant draft should not leak"),
            messagesAfterAssistantAppend: plan.prepared.messagesAfterUserAppend
        )
        let review = CognitionArtifact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000208")!,
            organ: .reviewer,
            title: "Review",
            summary: "No issue.",
            confidence: 0.9,
            jurisdiction: .turnContext,
            evidenceRefs: [],
            riskFlags: ["unsupported_memory_reference"]
        )

        let frame = CognitionDirector().frame(plan: plan, committed: committed, reviewArtifact: review)

        XCTAssertEqual(frame.turnId, turnId)
        XCTAssertEqual(frame.conversationId, conversationId)
        XCTAssertEqual(frame.assistantMessageId, assistantId)
        XCTAssertEqual(frame.records.first(where: { $0.label == "turn_steward" })?.status, .used)
        XCTAssertEqual(frame.records.first(where: { $0.label == "memory_retriever" })?.status, .used)
        XCTAssertEqual(frame.records.first(where: { $0.label == "skill_fold" })?.status, .used)
        XCTAssertEqual(frame.records.first(where: { $0.label == "provocation_judge" })?.status, .used)
        XCTAssertEqual(frame.records.first(where: { $0.label == "slow_cognition" })?.status, .used)
        XCTAssertEqual(frame.records.first(where: { $0.label == "agent_loop" })?.status, .used)
        XCTAssertEqual(frame.records.first(where: { $0.label == "reviewer" })?.status, .used)
        XCTAssertTrue(frame.records.contains { $0.resourceIds.contains("skill:\(skillId.uuidString)") })
        XCTAssertTrue(frame.records.contains { $0.resourceIds.contains("citation:\(citationId.uuidString)") })

        let encoded = String(data: try JSONEncoder().encode(frame), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("Help me plan"))
        XCTAssertFalse(encoded.contains("Assistant draft should not leak"))
    }

    func testFrameMarksOptionalOrgansSkippedWhenAbsent() {
        let plan = makePlan(
            promptTrace: PromptGovernanceTrace(
                promptLayers: ["anchor", "chat_mode"],
                evidenceAttached: false,
                safetyPolicyInvoked: true,
                highRiskQueryDetected: false,
                turnSteward: TurnStewardTrace(
                    route: .ordinaryChat,
                    memoryPolicy: .lean,
                    challengeStance: .useSilently,
                    responseShape: .answerNow,
                    projectSignalKind: nil,
                    source: .deterministic,
                    reason: "memory opt-out cue"
                ),
                agentCoordination: AgentCoordinationTrace(
                    executionMode: .singleShot,
                    quickActionMode: nil,
                    provider: .local,
                    reason: .ordinaryChatSingleShot,
                    indexedSkillCount: 0
                )
            ),
            judgeFallback: .providerLocal
        )
        let committed = CommittedAssistantTurn(
            node: plan.prepared.node,
            assistantMessage: Message(nodeId: plan.prepared.node.id, role: .assistant, content: "ok"),
            messagesAfterAssistantAppend: plan.prepared.messagesAfterUserAppend
        )

        let frame = CognitionDirector().frame(plan: plan, committed: committed, reviewArtifact: nil)

        XCTAssertEqual(frame.records.first(where: { $0.label == "memory_retriever" })?.status, .skipped)
        XCTAssertEqual(frame.records.first(where: { $0.label == "skill_fold" })?.status, .skipped)
        XCTAssertEqual(frame.records.first(where: { $0.label == "provocation_judge" })?.status, .skipped)
        XCTAssertEqual(frame.records.first(where: { $0.label == "slow_cognition" })?.status, .skipped)
        XCTAssertEqual(frame.records.first(where: { $0.label == "agent_loop" })?.status, .skipped)
        XCTAssertEqual(frame.records.first(where: { $0.label == "reviewer" })?.status, .skipped)
    }

    private func makePlan(
        turnId: UUID = UUID(),
        conversationId: UUID = UUID(),
        promptTrace: PromptGovernanceTrace,
        judgeFallback: JudgeFallbackReason,
        indexedSkillIds: Set<UUID> = [],
        loadedSkillIds: Set<UUID> = [],
        memoryEvidenceSourceIds: Set<UUID> = [],
        loadedCitationIds: Set<UUID> = []
    ) -> TurnPlan {
        let node = NousNode(id: conversationId, type: .conversation, title: "Current")
        let user = Message(nodeId: conversationId, role: .user, content: "Help me plan")
        return TurnPlan(
            turnId: turnId,
            prepared: PreparedConversationTurn(node: node, userMessage: user, messagesAfterUserAppend: [user]),
            citations: [],
            sourceMaterials: [],
            promptTrace: promptTrace,
            effectiveMode: .companion,
            nextQuickActionModeIfCompleted: nil,
            agentLoopMode: promptTrace.agentCoordination?.executionMode == .toolLoop ? .plan : nil,
            judgeEventDraft: JudgeEvent(
                id: UUID(),
                ts: Date(timeIntervalSince1970: 100),
                nodeId: conversationId,
                messageId: nil,
                chatMode: .companion,
                provider: .gemini,
                verdictJSON: "{}",
                fallbackReason: judgeFallback,
                userFeedback: nil,
                feedbackTs: nil
            ),
            turnSlice: TurnSystemSlice(stable: "stable prompt should not leak", volatile: "volatile prompt should not leak"),
            transcriptMessages: [],
            focusBlock: nil,
            provider: .gemini,
            indexedSkillIds: indexedSkillIds,
            loadedSkillIds: loadedSkillIds,
            memoryEvidenceSourceIds: memoryEvidenceSourceIds,
            loadedCitationIds: loadedCitationIds
        )
    }
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/CognitionDirectorTests CODE_SIGNING_ALLOWED=NO
```

Expected: compile fails because `CognitionDirector` does not exist.

- [ ] **Step 3: Implement director**

Create `Sources/Nous/Services/CognitionDirector.swift`:

```swift
import Foundation

final class CognitionDirector {
    func frame(
        plan: TurnPlan,
        committed: CommittedAssistantTurn,
        reviewArtifact: CognitionArtifact?
    ) -> CognitionFrame {
        let records = [
            stewardRecord(plan),
            memoryRecord(plan),
            skillRecord(plan),
            judgeRecord(plan),
            slowCognitionRecord(plan),
            agentLoopRecord(plan),
            reviewerRecord(reviewArtifact)
        ]

        let frame = CognitionFrame(
            turnId: plan.turnId,
            conversationId: committed.node.id,
            assistantMessageId: committed.assistantMessage.id,
            records: records.compactMap { try? $0.validated() }
        )
        return (try? frame.validated()) ?? CognitionFrame(
            turnId: plan.turnId,
            conversationId: committed.node.id,
            assistantMessageId: committed.assistantMessage.id,
            records: []
        )
    }

    private func stewardRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        let trace = plan.promptTrace.turnSteward
        let reason = [
            trace?.reason,
            trace.map { "route:\($0.route.rawValue)" },
            trace.map { "memory:\($0.memoryPolicy.rawValue)" }
        ]
            .compactMap { $0 }
            .joined(separator: " ")
        return CognitionOrganRecord(
            organ: .coordinator,
            label: "turn_steward",
            status: .used,
            reason: reason.isEmpty ? "turn_steward_trace_missing" : reason
        )
    }

    private func memoryRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        let resourceIds =
            plan.memoryEvidenceSourceIds.map { "memory_evidence:\($0.uuidString)" } +
            plan.loadedCitationIds.map { "citation:\($0.uuidString)" } +
            plan.memoryProvenance.keys.sorted().map { "memory_provenance:\($0)" }
        let used = plan.promptTrace.hasMemorySignal || !resourceIds.isEmpty
        return CognitionOrganRecord(
            organ: .coordinator,
            label: "memory_retriever",
            status: used ? .used : .skipped,
            reason: used ? "memory_signal_present" : "no_memory_signal",
            resourceIds: resourceIds
        )
    }

    private func skillRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        let resourceIds =
            plan.indexedSkillIds.map { "skill:\($0.uuidString)" } +
            plan.loadedSkillIds.map { "loaded_skill:\($0.uuidString)" }
        return CognitionOrganRecord(
            organ: .singleTurnToolLoop,
            label: "skill_fold",
            status: resourceIds.isEmpty ? .skipped : .used,
            reason: resourceIds.isEmpty ? "no_skills_matched_or_loaded" : "skills_available",
            resourceIds: resourceIds
        )
    }

    private func judgeRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        let fallback = plan.judgeEventDraft?.fallbackReason
        let status: CognitionOrganStatus = switch fallback {
        case .ok:
            .used
        case .timeout, .apiError, .badJSON, .unknownEntryId:
            .failed
        case .providerLocal, .judgeUnavailable, nil:
            .skipped
        }
        return CognitionOrganRecord(
            organ: .reviewer,
            label: "provocation_judge",
            status: status,
            reason: fallback?.rawValue ?? "judge_event_missing"
        )
    }

    private func slowCognitionRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        guard let trace = plan.promptTrace.slowCognitionTrace else {
            return CognitionOrganRecord(
                organ: .patternAnalyst,
                label: "slow_cognition",
                status: .skipped,
                reason: "no_slow_cognition_trace"
            )
        }
        return CognitionOrganRecord(
            organ: trace.organ,
            label: "slow_cognition",
            status: .used,
            reason: "slow_cognition_attached",
            resourceIds: ["artifact:\(trace.artifactId.uuidString)"] + trace.evidenceRefIds.map { "evidence:\($0)" }
        )
    }

    private func agentLoopRecord(_ plan: TurnPlan) -> CognitionOrganRecord {
        let coordination = plan.promptTrace.agentCoordination
        let used = coordination?.executionMode == .toolLoop
        return CognitionOrganRecord(
            organ: .singleTurnToolLoop,
            label: "agent_loop",
            status: used ? .used : .skipped,
            reason: coordination?.reason.rawValue ?? "agent_coordination_missing",
            resourceIds: plan.indexedSkillIds.map { "skill:\($0.uuidString)" }
        )
    }

    private func reviewerRecord(_ artifact: CognitionArtifact?) -> CognitionOrganRecord {
        guard let artifact else {
            return CognitionOrganRecord(
                organ: .reviewer,
                label: "reviewer",
                status: .skipped,
                reason: "no_review_artifact"
            )
        }
        return CognitionOrganRecord(
            organ: .reviewer,
            label: "reviewer",
            status: .used,
            reason: "silent_review_artifact",
            resourceIds: ["artifact:\(artifact.id.uuidString)"],
            riskFlags: artifact.riskFlags
        )
    }
}
```

- [ ] **Step 4: Verify GREEN**

Run the focused command from Step 2. Expected: `CognitionDirectorTests` passes.

---

### Task 3: Snapshot Factory And Inspector Feed

**Files:**
- Modify: `Sources/Nous/Services/ChatTurnRunner.swift`
- Modify: `Sources/Nous/Services/TurnCognitionInspectorFeed.swift`
- Modify: `Tests/NousTests/TurnCognitionInspectorFeedTests.swift`

- [ ] **Step 1: Add failing feed tests**

Append to `TurnCognitionInspectorFeedTests`:

```swift
func testRowsSummarizeCognitionFrameOrgans() {
    let now = Date(timeIntervalSince1970: 10_000)
    let frame = CognitionFrame(
        turnId: UUID(uuidString: "00000000-0000-0000-0000-000000000501")!,
        conversationId: UUID(uuidString: "00000000-0000-0000-0000-000000000502")!,
        assistantMessageId: UUID(uuidString: "00000000-0000-0000-0000-000000000503")!,
        records: [
            CognitionOrganRecord(organ: .coordinator, label: "turn_steward", status: .used, reason: "ordinary_chat"),
            CognitionOrganRecord(organ: .reviewer, label: "provocation_judge", status: .skipped, reason: "provider_local"),
            CognitionOrganRecord(organ: .reviewer, label: "reviewer", status: .failed, reason: "bad_json")
        ],
        createdAt: now
    )
    let row = TurnCognitionInspectorFeedFormatting.rows(
        from: [
            snapshot(
                suffix: "501",
                promptLayers: ["anchor"],
                slowCognitionAttached: false,
                cognitionFrame: frame,
                recordedAt: now
            )
        ],
        now: now
    )[0]

    XCTAssertEqual(row.organSummary, "3 organs: 1 used, 1 skipped, 1 failed")
    XCTAssertTrue(row.organDetail.contains("turn steward used"))
    XCTAssertTrue(row.organDetail.contains("provocation judge skipped: provider local"))
    XCTAssertTrue(row.organDetail.contains("reviewer failed: bad json"))
}

func testRowsHandleMissingCognitionFrame() {
    let now = Date(timeIntervalSince1970: 10_000)
    let row = TurnCognitionInspectorFeedFormatting.rows(
        from: [
            snapshot(
                suffix: "502",
                promptLayers: ["anchor"],
                slowCognitionAttached: false,
                cognitionFrame: nil,
                recordedAt: now
            )
        ],
        now: now
    )[0]

    XCTAssertEqual(row.organSummary, "No cognition frame")
    XCTAssertEqual(row.organDetail, "No organ trace")
}
```

Update the private `snapshot(...)` helper in that test file with:

```swift
cognitionFrame: CognitionFrame? = nil,
```

and pass `cognitionFrame: cognitionFrame` into `TurnCognitionSnapshot(...)`.

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/TurnCognitionInspectorFeedTests/testRowsSummarizeCognitionFrameOrgans -only-testing:NousTests/TurnCognitionInspectorFeedTests/testRowsHandleMissingCognitionFrame CODE_SIGNING_ALLOWED=NO
```

Expected: compile fails because `organSummary` and `organDetail` do not exist.

- [ ] **Step 3: Attach frames in the snapshot factory**

Modify `TurnCognitionSnapshotFactory.make(...)` in `ChatTurnRunner.swift`:

```swift
let cognitionFrame = CognitionDirector().frame(
    plan: plan,
    committed: committed,
    reviewArtifact: reviewArtifact
)
```

Pass `cognitionFrame: cognitionFrame` into `TurnCognitionSnapshot(...)`.

- [ ] **Step 4: Add inspector fields**

In `TurnCognitionInspectorRow`, add:

```swift
let organSummary: String
let organDetail: String
```

In row construction, pass:

```swift
organSummary: organSummary(snapshot.cognitionFrame),
organDetail: organDetail(snapshot.cognitionFrame)
```

Add helper formatters:

```swift
private static func organSummary(_ frame: CognitionFrame?) -> String {
    guard let frame else { return "No cognition frame" }
    let used = frame.records.filter { $0.status == .used }.count
    let skipped = frame.records.filter { $0.status == .skipped }.count
    let failed = frame.records.filter { $0.status == .failed }.count
    let count = frame.records.count
    return "\(count) \(plural("organ", count)): \(used) used, \(skipped) skipped, \(failed) failed"
}

private static func organDetail(_ frame: CognitionFrame?) -> String {
    guard let frame else { return "No organ trace" }
    guard !frame.records.isEmpty else { return "No organ records" }
    return frame.records
        .map { record in
            "\(display(record.label)) \(record.status.rawValue): \(display(record.reason))"
        }
        .joined(separator: ", ")
}
```

- [ ] **Step 5: Verify GREEN**

Run the focused command from Step 2. Expected: both feed tests pass.

---

### Task 4: Integration Verification

**Files:**
- All files touched above

- [ ] **Step 1: Run focused cognition tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/CognitionDirectorTests -only-testing:NousTests/CognitionContractsTests -only-testing:NousTests/TurnCognitionInspectorFeedTests CODE_SIGNING_ALLOWED=NO
```

Expected: all focused cognition tests pass.

- [ ] **Step 2: Run runner snapshot regression tests**

Run:

```bash
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ChatTurnRunnerShadowLearningTests/testRunnerRecordsTurnCognitionSnapshotAfterSuccessfulCommit -only-testing:NousTests/PromptGovernanceTraceTests/testRecordTurnCognitionSnapshotStoresLatestAndCountsWithoutPromptText CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Nous.xcodeproj -scheme NousTests -destination 'platform=macOS' -only-testing:NousTests/ChatTurnRunnerShadowLearningTests/testRunnerRecordsTurnCognitionSnapshotAfterSuccessfulCommit -only-testing:NousTests/GovernanceTelemetryStoreTests/testRecordTurnCognitionSnapshotStoresLatestAndCountsWithoutPromptText CODE_SIGNING_ALLOWED=NO
```

Expected: both tests pass and no stored snapshot includes raw prompt text.

- [ ] **Step 3: Run app build**

Run:

```bash
xcodebuild -project Nous.xcodeproj -scheme Nous -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

Expected: build succeeds.

- [ ] **Step 4: Run repo checks**

Run:

```bash
git diff --check
scripts/agentic_workflow_check.sh --bead <active-bead-id> --path docs/superpowers/specs/2026-05-05-cognition-director-v2-trace-first-design.md --path docs/superpowers/plans/2026-05-05-cognition-director-v2-trace-first.md --path Sources/Nous/Models/Cognition/CognitionContracts.swift --path Sources/Nous/Services/CognitionDirector.swift --path Sources/Nous/Services/ChatTurnRunner.swift --path Sources/Nous/Services/TurnCognitionInspectorFeed.swift --path Sources/Nous/Views/MemoryDebugInspector.swift --path Tests/NousTests/CognitionContractsTests.swift --path Tests/NousTests/CognitionDirectorTests.swift --path Tests/NousTests/TurnCognitionInspectorFeedTests.swift
```

Expected: both commands pass.
