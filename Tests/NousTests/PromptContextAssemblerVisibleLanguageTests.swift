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
}
