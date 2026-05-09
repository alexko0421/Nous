import XCTest
@testable import Nous

final class CitableContextBuilderTests: XCTestCase {

    var store: NodeStore!
    var builder: CitableContextBuilder!

    override func setUp() {
        super.setUp()
        store = try! NodeStore(path: ":memory:")
        builder = CitableContextBuilder(
            nodeStore: store,
            lexicalIndex: store.lexicalIndex
        )
    }

    override func tearDown() {
        builder = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Empty / no-match paths

    func testEmptyStoreReturnsEmptyContext() {
        let ctx = builder.build(
            turnText: "remember our decision",
            conversationId: UUID(),
            projectId: nil,
            mode: .companion
        )
        XCTAssertTrue(ctx.entries.isEmpty)
        XCTAssertEqual(ctx.manifest.totalCandidates, 0)
        XCTAssertEqual(ctx.manifest.admittedCount, 0)
        XCTAssertEqual(ctx.manifest.droppedByConfidenceFloor, 0)
        XCTAssertEqual(ctx.manifest.droppedByBudget, 0)
    }

    func testQueryWithoutHistoricalCueReturnsEmpty() throws {
        let atom = MemoryAtom(
            type: .decision,
            statement: "Ship before TTS is ready, citing momentum over polish.",
            scope: .global,
            confidence: 0.9
        )
        try store.insertMemoryAtom(atom)

        // No "remember" / "before" / "之前" cue → planner returns empty
        // (no intent classification, no vector fallback without embedding).
        let ctx = builder.build(
            turnText: "what should I do today",
            conversationId: UUID(),
            projectId: nil,
            mode: .companion
        )
        XCTAssertTrue(ctx.entries.isEmpty)
    }

    // MARK: - Atom lane

    func testAtomLaneAdmitsMatchingDecisionWithFullMetadata() throws {
        // Seed a real node first so the atom's sourceNodeId FK is satisfied.
        let node = NousNode(type: .conversation, title: "decision context", content: "")
        try store.insertNode(node)
        let eventTime = Date(timeIntervalSince1970: 5_000)
        let atom = MemoryAtom(
            type: .decision,
            statement: "Ship before TTS is ready, citing momentum over polish.",
            scope: .global,
            confidence: 0.85,
            eventTime: eventTime,
            sourceNodeId: node.id
        )
        try store.insertMemoryAtom(atom)

        let ctx = builder.build(
            turnText: "remember the decision we made before",
            conversationId: UUID(),
            projectId: nil,
            mode: .companion
        )

        let match = try XCTUnwrap(ctx.entries.first { $0.id == atom.id.uuidString })
        XCTAssertEqual(match.confidence, 0.85)
        XCTAssertEqual(match.eventTime, eventTime)
        XCTAssertEqual(match.sourceNodeId, node.id)
        XCTAssertEqual(match.atomType, .decision)
        XCTAssertEqual(match.scope, .global)
        XCTAssertEqual(match.promptAnnotation, "atom-recall")
        XCTAssertNotNil(match.recordedAt, "recordedAt should fall back to atom.updatedAt")
        XCTAssertEqual(ctx.manifest.intent, .decisionHistory)
    }

    func testConfidenceFloorDropsLowConfidenceAtom() throws {
        let lowConf = MemoryAtom(
            type: .decision,
            statement: "low-confidence decision",
            scope: .global,
            confidence: 0.4
        )
        let highConf = MemoryAtom(
            type: .decision,
            statement: "high-confidence decision",
            scope: .global,
            confidence: 0.9
        )
        try store.insertMemoryAtom(lowConf)
        try store.insertMemoryAtom(highConf)

        let ctx = builder.build(
            turnText: "remember the decision",
            conversationId: UUID(),
            projectId: nil,
            mode: .companion,
            confidenceFloor: 0.6
        )

        XCTAssertTrue(ctx.entries.contains { $0.id == highConf.id.uuidString })
        XCTAssertFalse(ctx.entries.contains { $0.id == lowConf.id.uuidString })
        XCTAssertGreaterThanOrEqual(ctx.manifest.droppedByConfidenceFloor, 1)
    }

    // MARK: - Reflection lane

    func testReflectionClaimAdmittedWithMetadata() throws {
        let recorded = Date(timeIntervalSince1970: 8_000)
        let claim = try seedReflection(
            projectId: nil,
            text: "Across three conversations this week, you grounded decisions in environment first.",
            confidence: 0.8,
            createdAt: recorded
        )

        let ctx = builder.build(
            turnText: "remember what we discussed",
            conversationId: UUID(),
            projectId: nil,
            mode: .companion
        )

        let match = try XCTUnwrap(ctx.entries.first { $0.id == claim.id.uuidString })
        XCTAssertEqual(match.scope, .selfReflection)
        XCTAssertEqual(match.confidence, 0.8)
        XCTAssertEqual(match.recordedAt, recorded)
        XCTAssertEqual(match.promptAnnotation, "weekly-reflection")
        XCTAssertNil(match.atomType, "reflections are not atoms")
    }

    func testReflectionLimitCapsClaimsBeforeRanking() throws {
        // Seed 5 active claims; reflectionLimit=2 should pick first 2 from store order.
        let now = Date()
        for i in 0..<5 {
            _ = try seedReflection(
                projectId: nil,
                text: "claim \(i)",
                confidence: 0.8,
                createdAt: now.addingTimeInterval(TimeInterval(-i * 86_400))
            )
        }

        let ctx = builder.build(
            turnText: "remember last week",
            conversationId: UUID(),
            projectId: nil,
            mode: .companion,
            reflectionLimit: 2
        )

        let reflections = ctx.entries.filter { $0.scope == .selfReflection }
        XCTAssertLessThanOrEqual(reflections.count, 2)
    }

    // MARK: - Budget cap

    func testCardCapEnforcedAcrossLanes() throws {
        // Fill atom + reflection lanes past the cap.
        for i in 0..<4 {
            try store.insertMemoryAtom(MemoryAtom(
                type: .decision,
                statement: "decision \(i)",
                scope: .global,
                confidence: 0.85
            ))
        }
        for i in 0..<3 {
            _ = try seedReflection(
                projectId: nil,
                text: "reflection \(i)",
                confidence: 0.8
            )
        }

        let ctx = builder.build(
            turnText: "remember the decision",
            conversationId: UUID(),
            projectId: nil,
            mode: .companion,
            cardCap: 3,
            atomLimit: 6,
            reflectionLimit: 3
        )

        XCTAssertLessThanOrEqual(ctx.entries.count, 3)
        XCTAssertEqual(ctx.manifest.admittedCount, ctx.entries.count)
        XCTAssertGreaterThan(ctx.manifest.droppedByBudget, 0,
                             "scoring produces more candidates than cardCap, so droppedByBudget must reflect the overflow")
    }

    // MARK: - Ranking

    func testHigherConfidenceOutranksLowerAtSameTypeAndAge() throws {
        let now = Date()
        let weak = MemoryAtom(
            type: .decision,
            statement: "weak",
            scope: .global,
            confidence: 0.65,
            eventTime: now,
            updatedAt: now
        )
        let strong = MemoryAtom(
            type: .decision,
            statement: "strong",
            scope: .global,
            confidence: 0.95,
            eventTime: now,
            updatedAt: now
        )
        try store.insertMemoryAtom(weak)
        try store.insertMemoryAtom(strong)

        let ctx = builder.build(
            turnText: "remember the decision",
            conversationId: UUID(),
            projectId: nil,
            mode: .companion,
            cardCap: 2,
            now: now
        )

        guard ctx.entries.count >= 2 else {
            XCTFail("expected both decisions admitted, got \(ctx.entries.count)")
            return
        }
        XCTAssertEqual(ctx.entries[0].id, strong.id.uuidString,
                       "higher-confidence atom must rank first")
    }

    func testManifestCapturesIntentAndMode() throws {
        try store.insertMemoryAtom(MemoryAtom(
            type: .decision,
            statement: "x",
            scope: .global,
            confidence: 0.9
        ))

        let ctx = builder.build(
            turnText: "remember the decision",
            conversationId: UUID(),
            projectId: nil,
            mode: .strategist
        )

        XCTAssertEqual(ctx.manifest.intent, .decisionHistory)
        XCTAssertEqual(ctx.manifest.mode, .strategist)
    }

    // MARK: - Block 6 / Step 3: lexical atom recall

    func testSearchMemoryAtomsDirectCJK3Char() throws {
        // 3+ char CJK queries hit pure-CJK indexed content via the trigram
        // tokenizer. (2-char CJK queries against pure-CJK content have a
        // known FTS5 trigram limitation — the LIKE-fallback for short
        // phrases is unreliable in our SQLite build. Realistic queries
        // typically have ≥3 char overlap.)
        let atom = MemoryAtom(
            type: .preference,
            statement: "面善嘅人通常有意识管理印象",
            scope: .global,
            confidence: 0.85
        )
        try store.insertMemoryAtom(atom)

        let hits = try store.lexicalIndex.searchMemoryAtoms(query: "面善嘅")
        XCTAssertFalse(hits.isEmpty,
                       "3-char CJK substring query must hit the indexed atom")
        XCTAssertEqual(hits.first?.rowId, atom.id)
    }

    func testSearchMemoryAtomsDirectEnglish() throws {
        let atom = MemoryAtom(
            type: .decision,
            statement: "Ship before TTS, citing momentum over polish",
            scope: .global,
            confidence: 0.85
        )
        try store.insertMemoryAtom(atom)

        let hits = try store.lexicalIndex.searchMemoryAtoms(query: "momentum")
        XCTAssertFalse(hits.isEmpty,
                       "English-only query 'momentum' must hit indexed atom")
        XCTAssertEqual(hits.first?.rowId, atom.id)
    }

    func testFtsTriggerPopulatesIndexOnAtomInsert() throws {
        // Sanity: confirm the AFTER INSERT trigger on memory_atoms is wired
        // and the FTS5 table receives a row when an atom is inserted.
        XCTAssertEqual(try store.lexicalIndex.debugMemoryAtomFtsRowCount(), 0,
                       "fresh :memory: store should have empty memory_atoms_fts")
        try store.insertMemoryAtom(MemoryAtom(
            type: .preference,
            statement: "面善嘅人通常有意识管理印象",
            scope: .global,
            confidence: 0.85
        ))
        XCTAssertEqual(try store.lexicalIndex.debugMemoryAtomFtsRowCount(), 1,
                       "trigger must fire and add a row to memory_atoms_fts")
    }

    func testLexicalLaneSurfacesAtomMissedByPlanner() throws {
        // Query that has NO historical-cue keyword ("remember"/"之前"/etc),
        // so MemoryQueryPlanner falls through with no intent and no vector
        // embedding given. Planner returns empty. Lexical lane should still
        // hit the atom via FTS5 trigram match on its statement.
        let atom = MemoryAtom(
            type: .preference,
            statement: "面善嘅人通常有意识管理印象，唔代表 confidence 真劲",
            scope: .global,
            confidence: 0.85
        )
        try store.insertMemoryAtom(atom)

        // No "remember" / "之前" trigger — planner intent classifier gets
        // nothing. Query overlap with atom: "通常有" (3 chars), well within
        // FTS5 trigram capabilities.
        let ctx = builder.build(
            turnText: "面善嘅人通常有几种解读法",
            conversationId: UUID(),
            projectId: nil,
            mode: .companion
        )

        XCTAssertTrue(ctx.entries.contains { $0.id == atom.id.uuidString },
                      "lexical FTS5 lane must surface the atom even when keyword intent classifier returns empty")
    }

    func testLexicalLaneDoesNotDuplicatePlannerHits() throws {
        // Atom that BOTH planner (via decisionHistory keyword) and lexical
        // would surface. The merged result should contain it once, not twice.
        let atom = MemoryAtom(
            type: .decision,
            statement: "Ship before TTS, citing momentum over polish.",
            scope: .global,
            confidence: 0.85
        )
        try store.insertMemoryAtom(atom)

        let ctx = builder.build(
            turnText: "remember the decision about TTS shipping",
            conversationId: UUID(),
            projectId: nil,
            mode: .companion
        )

        let matchCount = ctx.entries.filter { $0.id == atom.id.uuidString }.count
        XCTAssertEqual(matchCount, 1,
                       "atom that hits both planner and lexical lanes must dedupe to a single CitableEntry")
    }

    func testLexicalCJKQueryHitsAtomWithoutEmbedding() throws {
        // CJK query that an English-only embedding would miss; trigram
        // tokenizer in memory_atoms_fts catches the substring. Query has
        // 4-char overlap "软硬反差" with the atom statement.
        let atom = MemoryAtom(
            type: .preference,
            statement: "Alex 中意软硬反差嘅人，软系外表，硬系做嘢嗰阵",
            scope: .global,
            confidence: 0.8
        )
        try store.insertMemoryAtom(atom)

        let ctx = builder.build(
            turnText: "我中意软硬反差嘅类型",
            conversationId: UUID(),
            projectId: nil,
            mode: .companion
        )

        XCTAssertTrue(ctx.entries.contains { $0.id == atom.id.uuidString },
                      "trigram FTS5 must hit 「软硬」 substring even without an embedding")
    }

    // MARK: - Helpers

    @discardableResult
    private func seedReflection(
        projectId: UUID?,
        text: String,
        confidence: Double,
        createdAt: Date = Date()
    ) throws -> ReflectionClaim {
        if let projectId, try store.fetchProject(id: projectId) == nil {
            try store.insertProject(Project(id: projectId, title: "Test Project"))
        }
        let weekStart = createdAt.addingTimeInterval(-7 * 86400)
        let weekEnd = createdAt
        let run = ReflectionRun(
            projectId: projectId,
            weekStart: weekStart,
            weekEnd: weekEnd,
            ranAt: createdAt,
            status: .success,
            rejectionReason: nil,
            costCents: 0
        )
        let claim = ReflectionClaim(
            runId: run.id,
            claim: text,
            confidence: confidence,
            whyNonObvious: "why",
            status: .active,
            createdAt: createdAt
        )
        try store.persistReflectionRun(run, claims: [claim], evidence: [])
        return claim
    }
}
