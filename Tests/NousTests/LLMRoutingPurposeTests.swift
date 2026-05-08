import XCTest
@testable import Nous

final class LLMRoutingPurposeTests: XCTestCase {
    func test_foreground_equality_byMode() {
        let a = LLMRoutingPurpose.foreground(mode: .companion, quickAction: nil)
        let b = LLMRoutingPurpose.foreground(mode: .companion, quickAction: nil)
        let c = LLMRoutingPurpose.foreground(mode: .strategist, quickAction: nil)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_judge_and_reflection_are_distinct() {
        XCTAssertNotEqual(LLMRoutingPurpose.judge, LLMRoutingPurpose.reflection)
        XCTAssertNotEqual(
            LLMRoutingPurpose.judge,
            LLMRoutingPurpose.foreground(mode: nil, quickAction: nil)
        )
    }

    func test_isSendable_smoke() {
        // Compiles only if Sendable conformance holds.
        let _: any Sendable = LLMRoutingPurpose.judge
    }
}
