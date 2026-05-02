import XCTest
@testable import Nous

final class RotatingComposerPromptTests: XCTestCase {
    func testStartsWithDefaultPrompt() {
        let prompt = RotatingComposerPrompt()

        XCTAssertEqual(prompt.text(at: 0), "What are we thinking about tonight?")
    }

    func testNextIndexWrapsThroughPrompts() {
        let prompt = RotatingComposerPrompt(prompts: ["First", "Second"])

        XCTAssertEqual(prompt.nextIndex(after: 0), 1)
        XCTAssertEqual(prompt.nextIndex(after: 1), 0)
    }

    func testOnlyShowsWhenInputIsEmpty() {
        let prompt = RotatingComposerPrompt()

        XCTAssertTrue(prompt.shouldShow(inputText: "   "))
        XCTAssertFalse(prompt.shouldShow(inputText: "hello"))
    }

    func testOnlyAdvancesWhenEmptyAndNotFocused() {
        let prompt = RotatingComposerPrompt()

        XCTAssertTrue(prompt.shouldAdvance(inputText: "", isFocused: false))
        XCTAssertFalse(prompt.shouldAdvance(inputText: "", isFocused: true))
        XCTAssertFalse(prompt.shouldAdvance(inputText: "hello", isFocused: false))
    }
}
