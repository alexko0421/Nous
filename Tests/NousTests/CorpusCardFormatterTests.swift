import XCTest
@testable import Nous

final class CorpusCardFormatterTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_745_625_600) // 2025-04-26 UTC

    // MARK: - Header composition

    func testReflectionHeaderUsesReflectionLabelAndDate() {
        let entry = CitableEntry(
            id: "r1",
            text: "Across three conversations this week, you grounded decisions in environment first.",
            scope: .selfReflection,
            promptAnnotation: "weekly-reflection",
            confidence: 0.78,
            recordedAt: referenceDate
        )
        let card = try? XCTUnwrap(CorpusCardFormatter.formatCard(entry))
        XCTAssertNotNil(card)
        XCTAssertTrue(card!.hasPrefix("[reflection · 2025-04-26 · conf 0.78]\n"),
                      "got: \(card ?? "nil")")
    }

    func testAtomHeaderUsesAtomTypeRawValue() {
        let entry = CitableEntry(
            id: "a1",
            text: "Ship before TTS is ready, citing momentum over polish.",
            scope: .global,
            promptAnnotation: "atom-recall",
            confidence: 0.62,
            eventTime: referenceDate,
            atomType: .decision,
            recordedAt: referenceDate
        )
        let card = try? XCTUnwrap(CorpusCardFormatter.formatCard(entry))
        XCTAssertTrue(card!.hasPrefix("[decision · 2025-04-26 · conf 0.62]\n"),
                      "got: \(card ?? "nil")")
    }

    func testHighConfidenceDropsConfidenceSuffix() {
        let entry = CitableEntry(
            id: "a2",
            text: "Alex prefers async-first teams.",
            scope: .global,
            confidence: 0.95,
            atomType: .preference,
            recordedAt: referenceDate
        )
        let card = try? XCTUnwrap(CorpusCardFormatter.formatCard(entry))
        XCTAssertTrue(card!.hasPrefix("[preference · 2025-04-26]\n"),
                      "high-confidence (≥0.9) entries omit the conf suffix; got: \(card ?? "nil")")
    }

    func testEntryWithoutTypeOrDateProducesNoCard() {
        let entry = CitableEntry(
            id: "x",
            text: "ambient memory blob without provenance",
            scope: .global,
            confidence: 0.7
        )
        XCTAssertNil(CorpusCardFormatter.formatCard(entry),
                     "entries that lack any attribution metadata should not become cards")
    }

    func testEventTimePreferredOverRecordedAt() {
        let event = Date(timeIntervalSince1970: 1_745_625_600) // 2025-04-26
        let recorded = Date(timeIntervalSince1970: 1_748_217_600) // 2025-05-26
        let entry = CitableEntry(
            id: "a3",
            text: "decision text",
            scope: .global,
            confidence: 0.7,
            eventTime: event,
            atomType: .decision,
            recordedAt: recorded
        )
        let card = try? XCTUnwrap(CorpusCardFormatter.formatCard(entry))
        XCTAssertTrue(card!.contains("2025-04-26"),
                      "eventTime should win over recordedAt; got: \(card ?? "nil")")
        XCTAssertFalse(card!.contains("2025-05-26"))
    }

    // MARK: - Body formatting

    func testTextIsQuotedWhenPlain() {
        let entry = CitableEntry(
            id: "a4",
            text: "Just plain wisdom.",
            scope: .global,
            confidence: 0.7,
            atomType: .insight,
            recordedAt: referenceDate
        )
        let card = try? XCTUnwrap(CorpusCardFormatter.formatCard(entry))
        XCTAssertTrue(card!.hasSuffix("\"Just plain wisdom.\""),
                      "got: \(card ?? "nil")")
    }

    func testCantoneseQuotedTextIsNotDoubleQuoted() {
        let entry = CitableEntry(
            id: "a5",
            text: "「麻烦系一次性嘅，噪音系每一日」",
            scope: .global,
            confidence: 0.85,
            atomType: .insight,
            recordedAt: referenceDate
        )
        let card = try? XCTUnwrap(CorpusCardFormatter.formatCard(entry))
        XCTAssertTrue(card!.hasSuffix("「麻烦系一次性嘅，噪音系每一日」"),
                      "should not wrap text already opening with 「; got: \(card ?? "nil")")
    }

    // MARK: - Context-level formatting + budget

    func testFormatContextProducesEmptyContextNil() {
        let ctx = CitableContext.empty
        XCTAssertNil(CorpusCardFormatter.formatContext(ctx))
    }

    func testFormatContextSkipsNonCardableEntries() {
        // Mix one cardable with one without type/date — only the cardable
        // contributes to the output.
        let cardable = CitableEntry(
            id: "ok",
            text: "decision text",
            scope: .global,
            confidence: 0.65,
            atomType: .decision,
            recordedAt: referenceDate
        )
        let bare = CitableEntry(
            id: "bare",
            text: "no provenance",
            scope: .global
        )
        let ctx = CitableContext(
            entries: [cardable, bare],
            manifest: .empty
        )
        let output = try? XCTUnwrap(CorpusCardFormatter.formatContext(ctx))
        XCTAssertTrue(output!.contains("[decision · 2025-04-26 · conf 0.65]"))
        XCTAssertFalse(output!.contains("no provenance"))
    }

    func testTokenBudgetCapsCardCount() {
        // Each card is ~60 chars after formatting. With charsPerToken=4 and
        // tokenBudget=20, char limit = 80 — should admit only one card.
        let mkEntry: (Int) -> CitableEntry = { i in
            CitableEntry(
                id: "card\(i)",
                text: "Decision line number \(i) goes here.",
                scope: .global,
                confidence: 0.7,
                atomType: .decision,
                recordedAt: self.referenceDate
            )
        }
        let ctx = CitableContext(
            entries: (0..<5).map(mkEntry),
            manifest: .empty
        )
        let output = try? XCTUnwrap(CorpusCardFormatter.formatContext(
            ctx,
            tokenBudget: 20,
            charsPerToken: 4
        ))
        let cardCount = output!.components(separatedBy: "[decision").count - 1
        XCTAssertLessThanOrEqual(cardCount, 2,
                                 "20-token budget × 4 chars/token = 80 chars cap; only 1-2 cards fit")
        XCTAssertGreaterThanOrEqual(cardCount, 1)
    }

    func testNilTokenBudgetAdmitsAllCards() {
        let mkEntry: (Int) -> CitableEntry = { i in
            CitableEntry(
                id: "card\(i)",
                text: "decision \(i)",
                scope: .global,
                confidence: 0.7,
                atomType: .decision,
                recordedAt: self.referenceDate
            )
        }
        let ctx = CitableContext(
            entries: (0..<10).map(mkEntry),
            manifest: .empty
        )
        let output = try? XCTUnwrap(CorpusCardFormatter.formatContext(ctx, tokenBudget: nil))
        let cardCount = output!.components(separatedBy: "[decision").count - 1
        XCTAssertEqual(cardCount, 10)
    }

    func testCardsJoinedByBlankLine() {
        let a = CitableEntry(
            id: "a",
            text: "first",
            scope: .global,
            confidence: 0.7,
            atomType: .decision,
            recordedAt: referenceDate
        )
        let b = CitableEntry(
            id: "b",
            text: "second",
            scope: .global,
            confidence: 0.7,
            atomType: .insight,
            recordedAt: referenceDate
        )
        let ctx = CitableContext(entries: [a, b], manifest: .empty)
        let output = try? XCTUnwrap(CorpusCardFormatter.formatContext(ctx, tokenBudget: nil))
        XCTAssertTrue(output!.contains("\"first\"\n\n[insight"),
                      "cards must be separated by exactly one blank line; got: \(output ?? "nil")")
    }
}
