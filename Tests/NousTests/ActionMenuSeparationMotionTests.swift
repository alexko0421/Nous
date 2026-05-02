import XCTest
@testable import Nous

final class ActionMenuSeparationMotionTests: XCTestCase {
    func testCollapsedCapsuleStaysConnectedAtPlusSource() {
        let motion = ActionMenuSeparationMotion(
            sourceYOffset: 46,
            collapsedScale: CGSize(width: 0.24, height: 0.68)
        )

        XCTAssertEqual(motion.capsuleOffset(isExpanded: false).width, 0)
        XCTAssertEqual(motion.capsuleOffset(isExpanded: false).height, 46)
        XCTAssertEqual(motion.capsuleScale(isExpanded: false).width, 0.24)
        XCTAssertEqual(motion.capsuleScale(isExpanded: false).height, 0.68)
        XCTAssertEqual(motion.capsuleScale(isExpanded: true).width, 1)
        XCTAssertEqual(motion.capsuleScale(isExpanded: true).height, 1)
    }

    func testCollapsedItemsStayInsideSharedCapsule() {
        let motion = ActionMenuSeparationMotion()

        XCTAssertEqual(motion.itemOffset(for: 0, isExpanded: false), .zero)
        XCTAssertEqual(motion.itemOffset(for: 1, isExpanded: false), .zero)
        XCTAssertEqual(motion.itemOffset(for: 2, isExpanded: false), .zero)
    }

    func testOpeningDelaysStaggerContentInsideCapsule() {
        let motion = ActionMenuSeparationMotion()

        XCTAssertLessThan(motion.delay(for: 0, isExpanded: true), motion.delay(for: 1, isExpanded: true))
        XCTAssertLessThan(motion.delay(for: 1, isExpanded: true), motion.delay(for: 2, isExpanded: true))
    }

    func testClosingDelaysReverseBackTowardSource() {
        let motion = ActionMenuSeparationMotion()

        XCTAssertGreaterThan(motion.delay(for: 0, isExpanded: false), motion.delay(for: 1, isExpanded: false))
        XCTAssertGreaterThan(motion.delay(for: 1, isExpanded: false), motion.delay(for: 2, isExpanded: false))
    }
}
