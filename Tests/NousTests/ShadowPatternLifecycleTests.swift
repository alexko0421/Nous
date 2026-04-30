import XCTest
@testable import Nous

final class ShadowPatternLifecycleTests: XCTestCase {

    func testObservedPatternPromotesToSoftAfterEnoughEvidence() {
        let now = Date(timeIntervalSince1970: 1_000)
        let thirdEvidenceId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let pattern = makePattern(
            confidence: 0.59,
            weight: 0.25,
            status: .observed,
            evidenceMessageIds: [
                UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ],
            firstSeenAt: now.addingTimeInterval(-100),
            lastSeenAt: now.addingTimeInterval(-50)
        )

        let updated = ShadowPatternLifecycle.afterObservation(pattern, evidenceMessageId: thirdEvidenceId, at: now)

        XCTAssertEqual(updated.status, .soft)
        XCTAssertEqual(updated.evidenceMessageIds.count, 3)
        XCTAssertEqual(updated.evidenceMessageIds.last, thirdEvidenceId)
        XCTAssertEqual(updated.lastSeenAt, now)
        XCTAssertEqual(updated.lastReinforcedAt, now)
        XCTAssertEqual(updated.activeFrom, now)
        XCTAssertNil(updated.activeUntil)
        XCTAssertGreaterThanOrEqual(updated.confidence, 0.65)
        XCTAssertGreaterThanOrEqual(updated.weight, 0.30)
    }

    func testCorrectionWeakensStrongPatternAndSuppressesRecentPromptEligibility() {
        let now = Date(timeIntervalSince1970: 2_000)
        let pattern = makePattern(
            confidence: 0.90,
            weight: 0.80,
            status: .strong,
            evidenceMessageIds: evidenceIds(count: 5),
            firstSeenAt: now.addingTimeInterval(-500),
            lastSeenAt: now.addingTimeInterval(-100),
            lastReinforcedAt: now.addingTimeInterval(-100),
            activeFrom: now.addingTimeInterval(-400)
        )

        let updated = ShadowPatternLifecycle.afterCorrection(pattern, at: now)

        XCTAssertEqual(updated.status, .fading)
        XCTAssertEqual(updated.lastCorrectedAt, now)
        XCTAssertLessThan(updated.confidence, pattern.confidence)
        XCTAssertLessThan(updated.weight, pattern.weight)
        XCTAssertFalse(ShadowPatternLifecycle.isPromptEligible(updated, now: now.addingTimeInterval(60)))
    }

    func testStaleStrongPatternFadesAfterThirtyDays() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let staleDate = now.addingTimeInterval(-31 * 86_400)
        let pattern = makePattern(
            confidence: 0.86,
            weight: 0.62,
            status: .strong,
            evidenceMessageIds: evidenceIds(count: 5),
            firstSeenAt: staleDate.addingTimeInterval(-1_000),
            lastSeenAt: staleDate,
            lastReinforcedAt: staleDate,
            activeFrom: staleDate
        )

        let updated = ShadowPatternLifecycle.afterDecay(pattern, at: now)

        XCTAssertEqual(updated.status, .fading)
        XCTAssertLessThan(updated.confidence, pattern.confidence)
        XCTAssertLessThan(updated.weight, pattern.weight)
        XCTAssertNil(updated.activeUntil)
    }

    func testLowWeightStaleFadingPatternRetiresAfterSixtyDays() {
        let now = Date(timeIntervalSince1970: 6_000_000)
        let staleDate = now.addingTimeInterval(-61 * 86_400)
        let pattern = makePattern(
            confidence: 0.40,
            weight: 0.19,
            status: .fading,
            evidenceMessageIds: evidenceIds(count: 3),
            firstSeenAt: staleDate.addingTimeInterval(-1_000),
            lastSeenAt: staleDate,
            lastReinforcedAt: staleDate,
            activeFrom: staleDate
        )

        let updated = ShadowPatternLifecycle.afterDecay(pattern, at: now)

        XCTAssertEqual(updated.status, .retired)
        XCTAssertEqual(updated.activeUntil, now)
    }

    func testPromptEligibilityRequiresActiveStatusStrengthAndNoRecentCorrection() {
        let now = Date(timeIntervalSince1970: 8_000_000)
        let eligibleSoft = makePattern(
            confidence: 0.65,
            weight: 0.25,
            status: .soft,
            evidenceMessageIds: evidenceIds(count: 3),
            firstSeenAt: now.addingTimeInterval(-100),
            lastSeenAt: now
        )
        let eligibleStrong = makePattern(
            confidence: 0.82,
            weight: 0.55,
            status: .strong,
            evidenceMessageIds: evidenceIds(count: 5),
            firstSeenAt: now.addingTimeInterval(-100),
            lastSeenAt: now
        )
        let observed = makePattern(confidence: 0.90, weight: 0.90, status: .observed, firstSeenAt: now, lastSeenAt: now)
        let lowConfidence = makePattern(confidence: 0.64, weight: 0.90, status: .soft, firstSeenAt: now, lastSeenAt: now)
        let lowWeight = makePattern(confidence: 0.90, weight: 0.24, status: .soft, firstSeenAt: now, lastSeenAt: now)
        let recentlyCorrected = makePattern(
            confidence: 0.90,
            weight: 0.90,
            status: .strong,
            firstSeenAt: now,
            lastSeenAt: now,
            lastCorrectedAt: now.addingTimeInterval(-6 * 86_400)
        )
        let oldCorrection = makePattern(
            confidence: 0.90,
            weight: 0.90,
            status: .strong,
            firstSeenAt: now,
            lastSeenAt: now,
            lastCorrectedAt: now.addingTimeInterval(-8 * 86_400)
        )

        XCTAssertTrue(ShadowPatternLifecycle.isPromptEligible(eligibleSoft, now: now))
        XCTAssertTrue(ShadowPatternLifecycle.isPromptEligible(eligibleStrong, now: now))
        XCTAssertFalse(ShadowPatternLifecycle.isPromptEligible(observed, now: now))
        XCTAssertFalse(ShadowPatternLifecycle.isPromptEligible(lowConfidence, now: now))
        XCTAssertFalse(ShadowPatternLifecycle.isPromptEligible(lowWeight, now: now))
        XCTAssertFalse(ShadowPatternLifecycle.isPromptEligible(recentlyCorrected, now: now))
        XCTAssertTrue(ShadowPatternLifecycle.isPromptEligible(oldCorrection, now: now))
    }

    private func makePattern(
        id: UUID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        userId: String = "alex",
        kind: ShadowPatternKind = .thinkingMove,
        label: String = "First principles",
        summary: String = "Alex reaches for first principles.",
        promptFragment: String = "Use first principles before analogy.",
        triggerHint: String = "strategy",
        confidence: Double,
        weight: Double,
        status: ShadowPatternStatus,
        evidenceMessageIds: [UUID] = [],
        firstSeenAt: Date,
        lastSeenAt: Date,
        lastReinforcedAt: Date? = nil,
        lastCorrectedAt: Date? = nil,
        activeFrom: Date? = nil,
        activeUntil: Date? = nil
    ) -> ShadowLearningPattern {
        ShadowLearningPattern(
            id: id,
            userId: userId,
            kind: kind,
            label: label,
            summary: summary,
            promptFragment: promptFragment,
            triggerHint: triggerHint,
            confidence: confidence,
            weight: weight,
            status: status,
            evidenceMessageIds: evidenceMessageIds,
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt,
            lastReinforcedAt: lastReinforcedAt,
            lastCorrectedAt: lastCorrectedAt,
            activeFrom: activeFrom,
            activeUntil: activeUntil
        )
    }

    private func evidenceIds(count: Int) -> [UUID] {
        (0..<count).map { index in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
        }
    }
}
