import XCTest
@testable import Nous

final class MemoryQueryPlannerTests: XCTestCase {
    private var store: NodeStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try NodeStore(path: ":memory:")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func testThreeWeeksAgoDecisionRecallFiltersByEventTimeAndLogsWindow() throws {
        let now = makeDate(year: 2026, month: 4, day: 27, hour: 12)
        let threeWeeksAgo = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -21, to: now))
        let recent = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -3, to: now))

        let oldChain = try insertDecisionChain(
            eventTime: threeWeeksAgo,
            proposal: "Rewrite all memory at once.",
            rejection: "Alex rejected a broad memory rewrite.",
            reason: "The first slice needed to stay small.",
            replacement: "Ship graph recall incrementally."
        )
        _ = try insertDecisionChain(
            eventTime: recent,
            proposal: "Spend a week redesigning the sidebar.",
            rejection: "Alex rejected pausing memory work for sidebar polish.",
            reason: "Memory trust is the current bottleneck.",
            replacement: "Finish temporal graph recall first."
        )

        let packet = MemoryQueryPlanner(nodeStore: store).recallPacket(
            currentMessage: "我哋三周前否決過邊個方案，點解？",
            projectId: nil,
            conversationId: UUID(),
            now: now
        )

        XCTAssertEqual(packet.intent, .decisionHistory)
        XCTAssertEqual(packet.items.count, 1)
        XCTAssertTrue(packet.items[0].contains("Rewrite all memory at once."))
        XCTAssertTrue(packet.items[0].contains("The first slice needed to stay small."))
        XCTAssertFalse(packet.items[0].contains("sidebar polish"))
        XCTAssertTrue(packet.retrievedAtomIds.contains(oldChain.rejectionId))

        let start = try XCTUnwrap(packet.timeWindowStart)
        let end = try XCTUnwrap(packet.timeWindowEnd)
        XCTAssertTrue(threeWeeksAgo >= start && threeWeeksAgo <= end)
        XCTAssertFalse(recent >= start && recent <= end)

        let event = try XCTUnwrap(try store.fetchMemoryRecallEvents(limit: 1).first)
        XCTAssertEqual(event.intent, MemoryQueryIntent.decisionHistory.rawValue)
        XCTAssertEqual(event.timeWindowStart, packet.timeWindowStart)
        XCTAssertEqual(event.timeWindowEnd, packet.timeWindowEnd)
        XCTAssertTrue(event.retrievedAtomIds.contains(oldChain.rejectionId))
    }

    func testTemporalDecisionRecallDoesNotFallbackOutsideWindow() throws {
        let now = makeDate(year: 2026, month: 4, day: 27, hour: 12)
        let sixWeeksAgo = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -42, to: now))
        _ = try insertDecisionChain(
            eventTime: sixWeeksAgo,
            proposal: "Replace the graph with markdown files.",
            rejection: "Alex rejected markdown-only memory.",
            reason: "Markdown has no dedupe, decay, ranking, or conflict resolution.",
            replacement: "Use graph-backed recall."
        )

        let packet = MemoryQueryPlanner(nodeStore: store).recallPacket(
            currentMessage: "我哋三周前否決過邊個方案，點解？",
            projectId: nil,
            conversationId: UUID(),
            now: now
        )

        XCTAssertTrue(packet.items.isEmpty)
        XCTAssertTrue(try store.fetchMemoryRecallEvents(limit: 1).isEmpty)
    }

    func testLastMonthRuleRecallUsesCalendarMonth() throws {
        let now = makeDate(year: 2026, month: 4, day: 27, hour: 12)
        let march = makeDate(year: 2026, month: 3, day: 12, hour: 10)
        let april = makeDate(year: 2026, month: 4, day: 2, hour: 10)

        let marchRule = MemoryAtom(
            type: .rule,
            statement: "Do not store sensitive material without explicit consent.",
            scope: .global,
            confidence: 0.92,
            eventTime: march,
            createdAt: march,
            updatedAt: march
        )
        let aprilRule = MemoryAtom(
            type: .rule,
            statement: "Keep implementation slices small.",
            scope: .global,
            confidence: 0.9,
            eventTime: april,
            createdAt: april,
            updatedAt: april
        )
        try store.insertMemoryAtom(marchRule)
        try store.insertMemoryAtom(aprilRule)

        let packet = MemoryQueryPlanner(nodeStore: store).recallPacket(
            currentMessage: "你記唔記得我上個月講過咩 memory rule？",
            projectId: nil,
            conversationId: UUID(),
            now: now
        )

        XCTAssertEqual(packet.intent, .ruleRecall)
        XCTAssertEqual(packet.items.count, 1)
        XCTAssertTrue(packet.items[0].contains("sensitive material"))
        XCTAssertFalse(packet.items[0].contains("implementation slices"))
        XCTAssertEqual(packet.retrievedAtomIds, [marchRule.id])
    }

    func testRecentPreferenceOutranksStalePreferenceEvenWhenStaleHasHigherConfidence() throws {
        let now = makeDate(year: 2026, month: 4, day: 27, hour: 12)
        let staleDate = makeDate(year: 2025, month: 1, day: 2, hour: 10)
        let recentDate = makeDate(year: 2026, month: 4, day: 26, hour: 10)

        let stale = MemoryAtom(
            type: .preference,
            statement: "Alex prefers concise memory plans with broad architecture essays.",
            scope: .global,
            confidence: 0.99,
            eventTime: staleDate,
            createdAt: staleDate,
            updatedAt: staleDate
        )
        let recent = MemoryAtom(
            type: .preference,
            statement: "Alex prefers concise memory plans with concrete next steps.",
            scope: .global,
            confidence: 0.68,
            eventTime: recentDate,
            createdAt: recentDate,
            updatedAt: recentDate
        )
        try store.insertMemoryAtom(stale)
        try store.insertMemoryAtom(recent)

        let packet = MemoryQueryPlanner(nodeStore: store).recallPacket(
            currentMessage: "你記唔記得我 prefer concise memory plans 有咩偏好？",
            projectId: nil,
            conversationId: UUID(),
            limit: 2,
            now: now
        )

        XCTAssertEqual(packet.intent, .preferenceRecall)
        XCTAssertEqual(packet.retrievedAtomIds.first, recent.id)
        XCTAssertTrue(packet.items.first?.contains("concrete next steps") == true)
    }

    func testRecentlyReinforcedOldPreferenceStaysAheadOfUnseenOldPreference() throws {
        let now = makeDate(year: 2026, month: 4, day: 27, hour: 12)
        let oldDate = makeDate(year: 2025, month: 1, day: 2, hour: 10)
        let yesterday = makeDate(year: 2026, month: 4, day: 26, hour: 10)

        let stale = MemoryAtom(
            type: .preference,
            statement: "Alex prefers memory answers to include broad strategic commentary.",
            scope: .global,
            confidence: 0.82,
            eventTime: oldDate,
            createdAt: oldDate,
            updatedAt: oldDate
        )
        let reinforced = MemoryAtom(
            type: .preference,
            statement: "Alex prefers memory answers to include direct implementation evidence.",
            scope: .global,
            confidence: 0.82,
            eventTime: oldDate,
            createdAt: oldDate,
            updatedAt: oldDate,
            lastSeenAt: yesterday
        )
        try store.insertMemoryAtom(stale)
        try store.insertMemoryAtom(reinforced)

        let packet = MemoryQueryPlanner(nodeStore: store).recallPacket(
            currentMessage: "你記唔記得我 prefer memory answers 有咩偏好？",
            projectId: nil,
            conversationId: UUID(),
            limit: 2,
            now: now
        )

        XCTAssertEqual(packet.retrievedAtomIds.first, reinforced.id)
        XCTAssertTrue(packet.items.first?.contains("direct implementation evidence") == true)
    }

    func testExpiredActiveMemoryAtomIsNotRecalled() throws {
        let now = makeDate(year: 2026, month: 4, day: 27, hour: 12)
        let created = makeDate(year: 2026, month: 3, day: 20, hour: 10)
        let expired = makeDate(year: 2026, month: 4, day: 1, hour: 10)

        try store.insertMemoryAtom(MemoryAtom(
            type: .rule,
            statement: "Use the temporary launch checklist for all memory work.",
            scope: .global,
            confidence: 0.94,
            eventTime: created,
            validUntil: expired,
            createdAt: created,
            updatedAt: created
        ))

        let packet = MemoryQueryPlanner(nodeStore: store).recallPacket(
            currentMessage: "你記唔記得我之前講過咩 temporary launch checklist rule？",
            projectId: nil,
            conversationId: UUID(),
            now: now
        )

        XCTAssertTrue(packet.items.isEmpty)
        XCTAssertTrue(packet.retrievedAtomIds.isEmpty)
    }

    func testProjectRecallExcludesConversationAtomsFromOtherProjects() throws {
        let now = makeDate(year: 2026, month: 4, day: 27, hour: 12)
        let projectA = Project(title: "Galaxy")
        let projectB = Project(title: "Memory")
        try store.insertProject(projectA)
        try store.insertProject(projectB)

        let otherChat = NousNode(type: .conversation, title: "Other project", projectId: projectA.id)
        let currentProjectChat = NousNode(type: .conversation, title: "Current project", projectId: projectB.id)
        try store.insertNode(otherChat)
        try store.insertNode(currentProjectChat)

        let otherProjectAtom = MemoryAtom(
            type: .preference,
            statement: "Alex prefers memory UI to hide recall audit rows.",
            scope: .conversation,
            scopeRefId: otherChat.id,
            confidence: 0.96,
            eventTime: now,
            createdAt: now,
            updatedAt: now,
            sourceNodeId: otherChat.id
        )
        let currentProjectAtom = MemoryAtom(
            type: .preference,
            statement: "Alex prefers memory UI to show recall audit rows.",
            scope: .conversation,
            scopeRefId: currentProjectChat.id,
            confidence: 0.82,
            eventTime: now,
            createdAt: now,
            updatedAt: now,
            sourceNodeId: currentProjectChat.id
        )
        try store.insertMemoryAtom(otherProjectAtom)
        try store.insertMemoryAtom(currentProjectAtom)

        let packet = MemoryQueryPlanner(nodeStore: store).recallPacket(
            currentMessage: "你記唔記得我 prefer memory UI 有咩偏好？",
            projectId: projectB.id,
            conversationId: currentProjectChat.id,
            limit: 4,
            now: now
        )

        XCTAssertEqual(packet.retrievedAtomIds, [currentProjectAtom.id])
        XCTAssertTrue(packet.items.first?.contains("show recall audit rows") == true)
        XCTAssertFalse(packet.items.joined(separator: "\n").contains("hide recall audit rows"))
    }

    private func insertDecisionChain(
        eventTime: Date,
        proposal: String,
        rejection: String,
        reason: String,
        replacement: String
    ) throws -> (rejectionId: UUID, proposalId: UUID, reasonId: UUID, replacementId: UUID) {
        let node = NousNode(type: .conversation, title: proposal, content: "")
        try store.insertNode(node)
        let message = Message(
            nodeId: node.id,
            role: .user,
            content: "\(rejection) \(reason) \(replacement)",
            timestamp: eventTime
        )
        try store.insertMessage(message)

        let proposalAtom = MemoryAtom(
            type: .proposal,
            statement: proposal,
            scope: .conversation,
            scopeRefId: node.id,
            confidence: 0.88,
            eventTime: eventTime,
            createdAt: eventTime,
            updatedAt: eventTime,
            sourceNodeId: node.id,
            sourceMessageId: message.id
        )
        let rejectionAtom = MemoryAtom(
            type: .rejection,
            statement: rejection,
            scope: .conversation,
            scopeRefId: node.id,
            confidence: 0.9,
            eventTime: eventTime,
            createdAt: eventTime,
            updatedAt: eventTime,
            sourceNodeId: node.id,
            sourceMessageId: message.id
        )
        let reasonAtom = MemoryAtom(
            type: .reason,
            statement: reason,
            scope: .conversation,
            scopeRefId: node.id,
            confidence: 0.86,
            eventTime: eventTime,
            createdAt: eventTime,
            updatedAt: eventTime,
            sourceNodeId: node.id,
            sourceMessageId: message.id
        )
        let replacementAtom = MemoryAtom(
            type: .plan,
            statement: replacement,
            scope: .conversation,
            scopeRefId: node.id,
            confidence: 0.84,
            eventTime: eventTime,
            createdAt: eventTime,
            updatedAt: eventTime,
            sourceNodeId: node.id,
            sourceMessageId: message.id
        )

        try store.insertMemoryAtom(proposalAtom)
        try store.insertMemoryAtom(rejectionAtom)
        try store.insertMemoryAtom(reasonAtom)
        try store.insertMemoryAtom(replacementAtom)
        try store.insertMemoryEdge(MemoryEdge(
            fromAtomId: rejectionAtom.id,
            toAtomId: proposalAtom.id,
            type: .rejected,
            createdAt: eventTime,
            sourceMessageId: message.id
        ))
        try store.insertMemoryEdge(MemoryEdge(
            fromAtomId: rejectionAtom.id,
            toAtomId: reasonAtom.id,
            type: .because,
            createdAt: eventTime,
            sourceMessageId: message.id
        ))
        try store.insertMemoryEdge(MemoryEdge(
            fromAtomId: rejectionAtom.id,
            toAtomId: replacementAtom.id,
            type: .replacedBy,
            createdAt: eventTime,
            sourceMessageId: message.id
        ))

        return (rejectionAtom.id, proposalAtom.id, reasonAtom.id, replacementAtom.id)
    }

    /// Vector entry-point: when the user query has no keyword cue (so
    /// `intent(for:)` returns nil) but a `queryEmbedding` is provided,
    /// the planner must fall back to vector search and return the
    /// nearest active atoms in scope. Without this, paraphrased queries
    /// without cue words can never reach memory even when relevant atoms
    /// exist with embeddings.
    func testVectorFallbackRecallsRelevantAtomWhenNoKeywordCue() throws {
        let preference = MemoryAtom(
            type: .preference,
            statement: "Alex prefers direct, concise feedback.",
            scope: .global,
            status: .active,
            embedding: [1.0, 0.0, 0.0]
        )
        let belief = MemoryAtom(
            type: .belief,
            statement: "Distractions tax focus heavily.",
            scope: .global,
            status: .active,
            embedding: [0.0, 1.0, 0.0]
        )
        try store.insertMemoryAtom(preference)
        try store.insertMemoryAtom(belief)

        let packet = MemoryQueryPlanner(nodeStore: store).recallPacket(
            currentMessage: "Working on UI tweaks now.", // no cue words
            projectId: nil,
            conversationId: UUID(),
            queryEmbedding: [0.95, 0.05, 0.0],
            now: Date()
        )

        XCTAssertEqual(packet.intent, .generalRecall)
        XCTAssertEqual(packet.retrievedAtomIds.first, preference.id)
        XCTAssertTrue(packet.items.contains { $0.contains("direct, concise feedback") })
    }

    /// Vector fallback must rerank by `cosine × decay + confidenceBoost`,
    /// not raw cosine alone. A semantically-closer but stale + low-
    /// confidence atom should rank below a slightly-less-close fresh +
    /// high-confidence atom. Without rerank, vector recall surfaces
    /// confident-looking matches that are actually outdated, recreating
    /// the audit's "stale memory leaking into current answers" failure
    /// at the vector layer.
    func testVectorFallbackReranksUsingConfidenceAndRecency() throws {
        let now = Date()
        let stalePref = MemoryAtom(
            type: .preference,
            statement: "Alex prefers verbose outputs (stale).",
            scope: .global,
            status: .active,
            confidence: 0.3,
            eventTime: Calendar.current.date(byAdding: .day, value: -180, to: now),
            createdAt: Calendar.current.date(byAdding: .day, value: -180, to: now)!,
            updatedAt: Calendar.current.date(byAdding: .day, value: -180, to: now)!,
            lastSeenAt: Calendar.current.date(byAdding: .day, value: -180, to: now),
            embedding: [0.99, 0.14, 0.0]
        )
        let freshPref = MemoryAtom(
            type: .preference,
            statement: "Alex prefers concise outputs (fresh).",
            scope: .global,
            status: .active,
            confidence: 0.95,
            eventTime: now,
            createdAt: now,
            updatedAt: now,
            lastSeenAt: now,
            embedding: [0.85, 0.50, 0.0]
        )
        try [stalePref, freshPref].forEach(store.insertMemoryAtom)

        let packet = MemoryQueryPlanner(nodeStore: store).recallPacket(
            currentMessage: "Working through some output style questions",
            projectId: nil,
            conversationId: UUID(),
            queryEmbedding: [1.0, 0.0, 0.0],
            now: now
        )

        XCTAssertEqual(
            packet.retrievedAtomIds.first,
            freshPref.id,
            "Fresh + high-confidence atom must outrank stale + low-confidence one even when stale is closer in cosine."
        )
    }

    /// When keyword intent IS detected, vector fallback must NOT fire —
    /// the keyword path is more precise and we don't want vector noise
    /// shadowing well-targeted retrieval.
    func testVectorFallbackDoesNotFireWhenKeywordIntentMatched() throws {
        let preference = MemoryAtom(
            type: .preference,
            statement: "Alex prefers em-dashes off.",
            scope: .global,
            status: .active,
            embedding: [1.0, 0.0, 0.0]
        )
        try store.insertMemoryAtom(preference)

        // Query has a clear historical + decision cue → intent =
        // .decisionHistory. With no decision atoms in the store, the
        // packet should be empty — NOT polluted by the vector match
        // even though queryEmbedding is supplied.
        let packet = MemoryQueryPlanner(nodeStore: store).recallPacket(
            currentMessage: "What did we decide about three weeks ago?",
            projectId: nil,
            conversationId: UUID(),
            queryEmbedding: [0.95, 0.05, 0.0],
            now: Date()
        )

        XCTAssertNotEqual(packet.intent, .generalRecall)
        XCTAssertFalse(
            packet.retrievedAtomIds.contains(preference.id),
            "Vector fallback must not run when keyword intent is detected."
        )
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }
}
