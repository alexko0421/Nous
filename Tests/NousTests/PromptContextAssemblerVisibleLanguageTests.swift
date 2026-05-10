import XCTest
@testable import Nous

final class PromptContextAssemblerVisibleLanguageTests: XCTestCase {

    // MARK: - Helpers

    private func assemble(_ input: String?) -> TurnSystemSlice {
        PromptContextAssembler.assembleContext(
            currentUserInput: input,
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )
    }

    private func target(in slice: TurnSystemSlice) -> String? {
        let marker = "CURRENT VISIBLE RESPONSE LANGUAGE TARGET:"
        guard let range = slice.volatile.range(of: marker) else { return nil }
        let tail = slice.volatile[range.upperBound...]
        guard let line = tail.split(separator: "\n").first(where: { $0.hasPrefix("Target: ") }) else {
            return nil
        }
        return String(line).replacingOccurrences(of: "Target: ", with: "")
    }

    private func hasLanguageTargetBlock(_ slice: TurnSystemSlice) -> Bool {
        slice.volatile.contains("CURRENT VISIBLE RESPONSE LANGUAGE TARGET:")
    }

    // MARK: - Single-script detection

    func testLongEnglishMessageTargetsEnglish() {
        let slice = assemble("Hi, how does this app work? I'm trying it for the first time.")
        XCTAssertEqual(target(in: slice), "English")
    }

    func testPureCantoneseTargetsCantonese() {
        let slice = assemble("呢个系咪可以帮我嘅？我想知多啲。")
        XCTAssertEqual(target(in: slice), "Cantonese")
    }

    func testMandarinWithoutCantoneseMarkersTargetsMandarin() {
        let slice = assemble("这个应用程序可以帮助我做什么？")
        XCTAssertEqual(target(in: slice), "Mandarin")
    }

    /// Cantonese-first default for ambiguous pure-Chinese input. The screenshot bug
    /// was "解释下呢一篇" — has the Cantonese 呢 but none of the strong markers
    /// (嘅/咁/啲…), so under the old default it fell through to Mandarin and the
    /// reply came back in 普通话. With the new Cantonese-first default, ambiguous
    /// pure-Chinese (no Mandarin-specific marker either) targets Cantonese.
    func testAmbiguousPureChineseDefaultsToCantonese() {
        XCTAssertEqual(target(in: assemble("解释下呢一篇")), "Cantonese")
        XCTAssertEqual(target(in: assemble("睇下呢个")), "Cantonese")
        XCTAssertEqual(target(in: assemble("帮我想下")), "Cantonese")
    }

    /// Mandarin-specific markers (这/什么/怎么/没/们 + Traditional variants) flip
    /// ambiguous Chinese back to Mandarin. Keeps Mandarin testers covered.
    func testMandarinSpecificMarkerFlipsAmbiguousChineseToMandarin() {
        XCTAssertEqual(target(in: assemble("帮我看一下这个")), "Mandarin")
        XCTAssertEqual(target(in: assemble("这是什么意思")), "Mandarin")
        XCTAssertEqual(target(in: assemble("我们一起讨论")), "Mandarin")
        XCTAssertEqual(target(in: assemble("還沒想好怎麼做")), "Mandarin")
    }

    // MARK: - Short-input thresholds

    /// Boundary: 2-character English greetings ("hi", "ok", "yo", "no") cross the
    /// `latinCount >= 2` threshold and target English. Single letters remain
    /// unspecified to avoid spurious classification of typos / single keystrokes.
    func testTwoLatinCharsTargetEnglish() {
        XCTAssertEqual(target(in: assemble("hi")), "English")
        XCTAssertEqual(target(in: assemble("ok")), "English")
        XCTAssertEqual(target(in: assemble("yo")), "English")
    }

    func testSingleLatinCharFallsThroughAsUnspecified() {
        let slice = assemble("a")
        XCTAssertFalse(hasLanguageTargetBlock(slice),
                       "Single-letter input is too ambiguous to classify.")
    }

    // MARK: - Mixed-script handling

    /// English-dominant sentence with one Chinese proper noun ("醒目女仔" — the
    /// product/show name) should still target English. Threshold: latin >= 3×chinese.
    func testEnglishSentenceWithChineseProperNounTargetsEnglish() {
        let slice = assemble("Tell me about 醒目女仔")
        XCTAssertEqual(target(in: slice), "English")
    }

    func testEnglishQuestionWithChineseTermTargetsEnglish() {
        let slice = assemble("What does 倾偈 mean in this app?")
        XCTAssertEqual(target(in: slice), "English")
    }

    /// Cantonese sentence with English tokens ("app", "React", "PR") must stay
    /// Cantonese as long as a Cantonese marker (嘅/咁/啲/喺/系咪/我哋/...) is present.
    /// Marker presence is unambiguous and overrides ratio.
    func testCantoneseSentenceWithEnglishTokensStaysCantonese() {
        let slice = assemble("呢个 app 系咪可以帮我嘅？")
        XCTAssertEqual(target(in: slice), "Cantonese")
    }

    func testCantoneseSentenceWithMultipleEnglishTokensStaysCantonese() {
        let slice = assemble("我用 React 嘅时候发现 hooks 有问题")
        XCTAssertEqual(target(in: slice), "Cantonese")
    }

    /// Mandarin-dominant sentence with one English proper noun ("React") should
    /// target Mandarin via the chinese >= 3×latin ratio (no Cantonese markers present).
    func testMandarinSentenceWithEnglishProperNounTargetsMandarin() {
        let slice = assemble("我想了解一下 React 这个框架的工作原理是什么")
        XCTAssertEqual(target(in: slice), "Mandarin")
    }

    /// Genuine balanced mix (no Cantonese marker, neither script dominates 2:1)
    /// stays Mixed — the model legitimately mirrors the user's natural blend.
    func testGenuinelyBalancedMixTargetsMixed() {
        // 2 latin chars + 2 chinese chars → neither side reaches 2× the other.
        let slice = assemble("Hi 你好")
        XCTAssertEqual(target(in: slice), "Mixed")
    }

    // MARK: - Explicit language requests

    func testExplicitEnglishRequestOverridesChineseBody() {
        let slice = assemble("用英文回答呢个问题")
        XCTAssertEqual(target(in: slice), "English")
    }

    func testExplicitCantoneseKeywordTargetsCantonese() {
        let slice = assemble("Please respond in cantonese from now on")
        XCTAssertEqual(target(in: slice), "Cantonese")
    }

    func testExplicitMandarinKeywordTargetsMandarin() {
        let slice = assemble("Please respond in mandarin from now on")
        XCTAssertEqual(target(in: slice), "Mandarin")
    }

    // MARK: - Empty / non-text inputs

    func testNilInputSkipsTargetBlock() {
        let slice = assemble(nil)
        XCTAssertFalse(hasLanguageTargetBlock(slice))
    }

    func testWhitespaceOnlyInputSkipsTargetBlock() {
        let slice = assemble("   \n  ")
        XCTAssertFalse(hasLanguageTargetBlock(slice))
    }

    func testEmojiOnlyInputSkipsTargetBlock() {
        let slice = assemble("👋")
        XCTAssertFalse(hasLanguageTargetBlock(slice),
                       "Emoji-only input has no latin or Chinese scalars and falls through.")
    }

    func testDigitsOnlyInputSkipsTargetBlock() {
        let slice = assemble("12345")
        XCTAssertFalse(hasLanguageTargetBlock(slice),
                       "Digits-only input has no latin or Chinese scalars and falls through.")
    }

    // MARK: - Stable policy is always present

    func testStableLanguagePolicyAlwaysPresentRegardlessOfTarget() {
        let slice = assemble("a")
        XCTAssertTrue(slice.stable.contains("VISIBLE RESPONSE LANGUAGE POLICY"),
                      "Stable policy must remain even when no per-turn target is injected.")
    }

    /// The stable policy must phrase the rule as a hard requirement (MUST) rather than
    /// a soft default. Soft wording ("by default", "match... unless") gave the LLM
    /// room to drift back to Alex's usual Cantonese voice on English input.
    func testStableLanguagePolicyUsesHardRuleWording() {
        let slice = assemble("hi")
        XCTAssertTrue(slice.stable.contains("MUST use the same language"),
                      "Stable policy must phrase language matching as a hard rule, not a default.")
        XCTAssertTrue(slice.stable.contains("overrides anchor examples"),
                      "Stable policy must explicitly override anchor / memory / prior-turn drift.")
    }

    // MARK: - Quick action opening override

    /// Quick-action opening turns pass a synthetic English instruction as the seed.
    /// Without an override that would classify the turn as English under the hardened
    /// MUST rule, forcing the LLM to greet Alex in English. The override must let the
    /// runner force Cantonese (anchor voice) regardless of the synthetic input.
    func testVisibleLanguageOverrideForcesCantoneseDespiteEnglishInput() {
        let slice = PromptContextAssembler.assembleContext(
            currentUserInput: "Alex just entered the Brainstorm mode from the welcome screen. Read his recent conversations.",
            visibleLanguageTargetOverride: .cantonese,
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )
        XCTAssertEqual(target(in: slice), "Cantonese",
                       "Override must beat the heuristic — opening turns must default to anchor voice.")
    }

    /// Override also works when no currentUserInput is supplied (the path the runner
    /// actually takes — passes nil and forces Cantonese).
    func testVisibleLanguageOverrideForcesCantoneseWhenInputIsNil() {
        let slice = PromptContextAssembler.assembleContext(
            currentUserInput: nil,
            visibleLanguageTargetOverride: .cantonese,
            globalMemory: nil,
            projectMemory: nil,
            conversationMemory: nil,
            recentConversations: [],
            citations: [],
            projectGoal: nil
        )
        XCTAssertEqual(target(in: slice), "Cantonese")
    }

    // MARK: - Enumerable list format policy

    /// Policy must be present in stable so the LLM emits numbered lists when listing
    /// 3+ discrete sections (e.g. article breakdown that Alex then references with
    /// "第二个部分"). Lives in stable so it survives across all chat modes.
    func testEnumerableListFormatPolicyIsPresentInStable() {
        let slice = assemble("hi")
        XCTAssertTrue(slice.stable.contains("ENUMERABLE LIST FORMAT POLICY"),
                      "Stable system prompt must include the numbered-list rule.")
        XCTAssertTrue(slice.stable.contains("numbered markdown list"),
                      "Policy must direct the model toward `1. 2. 3.` numbering for discrete enumerations.")
    }
}
