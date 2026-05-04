import XCTest
@testable import Nous

final class DisclosurePillMotionTests: XCTestCase {
    func testCollapsedStateClipsContentUnderPillWithoutMovingThroughIt() {
        let motion = DisclosurePillMotion()

        XCTAssertEqual(motion.visibleContentHeight(fullHeight: 84, isExpanded: false), 0)
        XCTAssertEqual(motion.contentOffsetY(isExpanded: false), 0)
        XCTAssertEqual(motion.contentOpacity(isExpanded: false), 0)
        XCTAssertLessThan(motion.contentScaleY(isExpanded: false), 1)
        XCTAssertGreaterThan(motion.contentBlur(isExpanded: false), 0)
    }

    func testExpandedStateShowsContentAtNaturalHeight() {
        let motion = DisclosurePillMotion()

        XCTAssertEqual(motion.visibleContentHeight(fullHeight: 84, isExpanded: true), 84)
        XCTAssertEqual(motion.contentOffsetY(isExpanded: true), 0)
        XCTAssertEqual(motion.contentOpacity(isExpanded: true), 1)
        XCTAssertEqual(motion.contentScaleY(isExpanded: true), 1)
        XCTAssertEqual(motion.contentBlur(isExpanded: true), 0)
    }

    func testSpacingOnlyAppearsWhenDisclosureIsOpen() {
        let motion = DisclosurePillMotion(expandedSpacing: 6)

        XCTAssertEqual(motion.contentSpacing(isExpanded: false), 0)
        XCTAssertEqual(motion.contentSpacing(isExpanded: true), 6)
    }
}
