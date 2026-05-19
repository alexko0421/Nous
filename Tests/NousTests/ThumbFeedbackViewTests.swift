import XCTest
import SwiftUI
@testable import Nous

final class ThumbFeedbackViewTests: XCTestCase {
    func testInitialVerdictIsUnset() {
        var verdict = ThumbVerdict.unset
        var note = ""
        var calls: [(ThumbVerdict, String)] = []
        _ = ThumbFeedbackView(
            verdict: Binding(get: { verdict }, set: { verdict = $0 }),
            note: Binding(get: { note }, set: { note = $0 }),
            onChange: { v, n in calls.append((v, n)) }
        )
        XCTAssertEqual(verdict, .unset)
        XCTAssertTrue(calls.isEmpty)
    }

    func testChatFeedbackViewCanBeConstructed() {
        _ = ThumbFeedbackView(
            verdict: .constant(.unset),
            note: .constant(""),
            onChange: { _, _ in }
        )
    }
}
