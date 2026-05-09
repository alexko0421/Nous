import XCTest
@testable import Nous

final class CorpusFidelityCheckerTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_745_625_600) // 2025-04-26

    // MARK: - Empty inputs

    func testEmptyReplyAndEmptyCorpusProducesEmptySignal() {
        let signal = CorpusFidelityChecker.check(
            reply: "",
            corpusContext: .empty
        )
        XCTAssertEqual(signal.borrowedAuthorityHits, [])
        XCTAssertEqual(signal.ownCorpusCitedIds, [])
        XCTAssertEqual(signal.ownCorpusCitationRate, 0.0)
        XCTAssertEqual(signal.ownCorpusAvailableCount, 0)
    }

    func testRateIsZeroWithoutDivisionByZeroWhenCorpusEmpty() {
        let signal = CorpusFidelityChecker.check(
            reply: "any reply text whatsoever",
            corpusContext: .empty
        )
        XCTAssertEqual(signal.ownCorpusCitationRate, 0.0)
        XCTAssertEqual(signal.ownCorpusAvailableCount, 0)
    }

    // MARK: - Borrowed-authority detection

    func testDetectsBezosTypeFrameworkReference() {
        let signal = CorpusFidelityChecker.check(
            reply: "可以参考 Bezos 嘅 Type 1 / Type 2 决定区分。",
            corpusContext: .empty
        )
        XCTAssertTrue(signal.borrowedAuthorityHits.contains("Bezos"))
        XCTAssertTrue(signal.borrowedAuthorityHits.contains { $0.contains("Type 1 / Type 2") || $0.contains("Type 1") })
    }

    func testDetectsKahnemanSystemReference() {
        let signal = CorpusFidelityChecker.check(
            reply: "Kahneman 嘅 System 1 思维模式可以解释呢种反应。",
            corpusContext: .empty
        )
        XCTAssertTrue(signal.borrowedAuthorityHits.contains("Kahneman"))
        XCTAssertTrue(signal.borrowedAuthorityHits.contains("System 1"))
    }

    func testDetectsFirstPrinciplesAsCanonicalPhrase() {
        let signal = CorpusFidelityChecker.check(
            reply: "用 first principles 嘅角度睇下。",
            corpusContext: .empty
        )
        XCTAssertTrue(signal.borrowedAuthorityHits.contains("first principles"))
    }

    func testDetectionIsCaseInsensitive() {
        let signal = CorpusFidelityChecker.check(
            reply: "BEZOS 同 kahneman 都讲过类似嘢。",
            corpusContext: .empty
        )
        XCTAssertTrue(signal.borrowedAuthorityHits.contains("Bezos"))
        XCTAssertTrue(signal.borrowedAuthorityHits.contains("Kahneman"))
    }

    func testCleanReplyHasZeroBorrowedAuthorityHits() {
        let signal = CorpusFidelityChecker.check(
            reply: "你之前讲过呢个决定嘅时候已经做过区分。",
            corpusContext: .empty
        )
        XCTAssertEqual(signal.borrowedAuthorityHits, [])
    }

    // MARK: - Own-corpus citation detection

    func testQuotedEntryCountsAsCitation() {
        let entry = CitableEntry(
            id: "atom-1",
            text: "Your decisions tend to lag when meaning is unclear.",
            scope: .global,
            confidence: 0.78,
            recordedAt: referenceDate
        )
        let ctx = CitableContext(entries: [entry], manifest: .empty)
        let reply = "你之前讲过 Your decisions tend to lag when meaning is unclear，咁今次都系一样。"

        let signal = CorpusFidelityChecker.check(reply: reply, corpusContext: ctx)
        XCTAssertEqual(signal.ownCorpusCitedIds, ["atom-1"])
        XCTAssertEqual(signal.ownCorpusCitationRate, 1.0)
        XCTAssertEqual(signal.ownCorpusAvailableCount, 1)
    }

    func testReplyWithNoOverlapHasZeroCitations() {
        let entry = CitableEntry(
            id: "atom-1",
            text: "Your decisions tend to lag when meaning is unclear.",
            scope: .global,
            confidence: 0.78,
            recordedAt: referenceDate
        )
        let ctx = CitableContext(entries: [entry], manifest: .empty)
        let reply = "Bezos 嘅 Type 1 决定可以快速决定。"

        let signal = CorpusFidelityChecker.check(reply: reply, corpusContext: ctx)
        XCTAssertEqual(signal.ownCorpusCitedIds, [])
        XCTAssertEqual(signal.ownCorpusCitationRate, 0.0)
        XCTAssertEqual(signal.ownCorpusAvailableCount, 1,
                       "the corpus had 1 available entry — the rate of 0 means 'ignored corpus', not 'no corpus'")
    }

    func testCitationRateIsFractionOfCitedOverAvailable() {
        let cited = CitableEntry(
            id: "cited",
            text: "Some long enough text that overlaps directly here.",
            scope: .global,
            confidence: 0.7,
            recordedAt: referenceDate
        )
        let ignored1 = CitableEntry(
            id: "ignored1",
            text: "A different uncited statement entirely.",
            scope: .global,
            confidence: 0.7,
            recordedAt: referenceDate
        )
        let ignored2 = CitableEntry(
            id: "ignored2",
            text: "Another uncited atom about something else.",
            scope: .global,
            confidence: 0.7,
            recordedAt: referenceDate
        )
        let ctx = CitableContext(
            entries: [cited, ignored1, ignored2],
            manifest: .empty
        )
        let reply = "Some long enough text that overlaps directly here is what you said before."

        let signal = CorpusFidelityChecker.check(reply: reply, corpusContext: ctx)
        XCTAssertEqual(signal.ownCorpusCitedIds, ["cited"])
        XCTAssertEqual(signal.ownCorpusCitationRate, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(signal.ownCorpusAvailableCount, 3)
    }

    func testShortEntriesRequireWholeTextMatch() {
        // Entry shorter than minLength (15 chars) — overlap requires full match.
        let entry = CitableEntry(
            id: "short",
            text: "ship now",  // 8 chars
            scope: .global,
            confidence: 0.7,
            recordedAt: referenceDate
        )
        let ctx = CitableContext(entries: [entry], manifest: .empty)

        // Partial substring of "ship now" should NOT match (whole text required).
        let signalPartial = CorpusFidelityChecker.check(
            reply: "Let's ship something soon.",  // contains "ship" but not "ship now"
            corpusContext: ctx
        )
        XCTAssertEqual(signalPartial.ownCorpusCitedIds, [])

        // Full text "ship now" embedded → matches.
        let signalFull = CorpusFidelityChecker.check(
            reply: "OK, let's ship now and iterate.",
            corpusContext: ctx
        )
        XCTAssertEqual(signalFull.ownCorpusCitedIds, ["short"])
    }

    func testCantoneseSubstringOverlapWorks() {
        let entry = CitableEntry(
            id: "cant-1",
            text: "麻烦系一次性嘅，噪音系每一日。",
            scope: .global,
            confidence: 0.85,
            recordedAt: referenceDate
        )
        let ctx = CitableContext(entries: [entry], manifest: .empty)
        let reply = "我谂返起你之前讲过：麻烦系一次性嘅，噪音系每一日。咁就明显啦。"

        let signal = CorpusFidelityChecker.check(reply: reply, corpusContext: ctx)
        XCTAssertEqual(signal.ownCorpusCitedIds, ["cant-1"])
    }

    // MARK: - Combined leakage scenarios

    func testCombinedLeakageAndCitationCoexist() {
        let entry = CitableEntry(
            id: "alex-quote",
            text: "Your decisions tend to lag when meaning is unclear.",
            scope: .global,
            confidence: 0.78,
            recordedAt: referenceDate
        )
        let ctx = CitableContext(entries: [entry], manifest: .empty)
        // Reply quotes Alex's own corpus AND borrows from Kahneman → both signals fire.
        let reply = "Your decisions tend to lag when meaning is unclear — 类似 Kahneman 嘅 System 1 / System 2 区分。"

        let signal = CorpusFidelityChecker.check(reply: reply, corpusContext: ctx)
        XCTAssertEqual(signal.ownCorpusCitedIds, ["alex-quote"])
        XCTAssertEqual(signal.ownCorpusCitationRate, 1.0)
        XCTAssertTrue(signal.borrowedAuthorityHits.contains("Kahneman"))
        XCTAssertTrue(signal.borrowedAuthorityHits.contains("System 1") || signal.borrowedAuthorityHits.contains("System 2"))
    }

    func testHighFidelityCleanReply() {
        // Quote own corpus, no borrowed authorities — best-case turn.
        let entry = CitableEntry(
            id: "win",
            text: "你 2025-12-15 决定 ship momentum over polish 嗰阵嘅判断。",
            scope: .global,
            confidence: 0.85,
            recordedAt: referenceDate
        )
        let ctx = CitableContext(entries: [entry], manifest: .empty)
        let reply = "你 2025-12-15 决定 ship momentum over polish 嗰阵嘅判断 同今次系同一个 pattern。"

        let signal = CorpusFidelityChecker.check(reply: reply, corpusContext: ctx)
        XCTAssertEqual(signal.borrowedAuthorityHits, [])
        XCTAssertEqual(signal.ownCorpusCitedIds, ["win"])
        XCTAssertEqual(signal.ownCorpusCitationRate, 1.0)
    }
}
