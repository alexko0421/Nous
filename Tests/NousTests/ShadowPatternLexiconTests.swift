import XCTest
@testable import Nous

final class ShadowPatternLexiconTests: XCTestCase {
    func testMatchesCantoneseAndChineseAliasesToCurrentLabels() {
        let lexicon = ShadowPatternLexicon.shared

        XCTAssertTrue(lexicon.matchesObservation(label: "pain_test_for_product_scope", text: "冇呢样嘢，会痛唔痛？"))
        XCTAssertTrue(lexicon.matchesObservation(label: "inversion_before_recommendation", text: "先谂下最坏版本会系点"))
        XCTAssertTrue(lexicon.matchesObservation(label: "concrete_over_generic", text: "唔好讲到太泛，畀个具体例子"))
        XCTAssertTrue(lexicon.matchesObservation(label: "direct_pushback_when_wrong", text: "如果我错，直接说，唔好顺住我"))
        XCTAssertTrue(lexicon.matchesObservation(label: "organize_before_judging", text: "我讲到好乱，帮我整理先"))
        XCTAssertTrue(lexicon.matchesObservation(label: "first_principles_decision_frame", text: "用第一性原理重新睇一次"))
    }

    func testUnrelatedCantoneseDoesNotMatchAnyPattern() {
        let matches = ShadowPatternLexicon.shared.matchingLabels(in: "今日食咩好？")

        XCTAssertTrue(matches.isEmpty)
    }

    func testShortGenericAliasesAreNotAcceptedAsStandaloneMatches() {
        let lexicon = ShadowPatternLexicon.shared

        XCTAssertFalse(lexicon.matchesObservation(label: "concrete_over_generic", text: "具体"))
        XCTAssertFalse(lexicon.matchesObservation(label: "first_principles_decision_frame", text: "本质"))
        XCTAssertFalse(lexicon.matchesObservation(label: "inversion_before_recommendation", text: "最坏"))
        XCTAssertFalse(lexicon.matchesObservation(label: "pain_test_for_product_scope", text: "absence"))
    }

    func testInitializerFiltersShortGenericAliases() {
        let lexicon = ShadowPatternLexicon(aliasesByLabel: [
            "custom": ["具体", "本质", "absence", "具体例子", "pain test", "inversion"]
        ])

        XCTAssertFalse(lexicon.matchesObservation(label: "custom", text: "具体"))
        XCTAssertFalse(lexicon.matchesObservation(label: "custom", text: "本质"))
        XCTAssertFalse(lexicon.matchesObservation(label: "custom", text: "absence"))
        XCTAssertTrue(lexicon.matchesObservation(label: "custom", text: "具体例子"))
        XCTAssertTrue(lexicon.matchesObservation(label: "custom", text: "pain test"))
        XCTAssertTrue(lexicon.matchesObservation(label: "custom", text: "inversion"))
    }

    func testAliasMatchBonusIsBinary() {
        let lexicon = ShadowPatternLexicon.shared

        XCTAssertEqual(
            lexicon.aliasMatchBonus(label: "pain_test_for_product_scope", text: "会痛唔痛？"),
            0.45,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            lexicon.aliasMatchBonus(label: "pain_test_for_product_scope", text: "冇呢样嘢，会痛唔痛？pain test"),
            0.45,
            accuracy: 0.0001
        )
    }

    func testNormalizationHandlesCaseAndFullWidthSpaces() {
        let lexicon = ShadowPatternLexicon.shared

        XCTAssertTrue(lexicon.matchesObservation(label: "pain_test_for_product_scope", text: "PAIN　TEST 呢关过唔到"))
        XCTAssertTrue(lexicon.matchesObservation(label: "direct_pushback_when_wrong", text: "请你 PUSH BACK"))
    }
}
