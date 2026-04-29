import XCTest
@testable import Nous

final class GhostCursorTravelDurationTests: XCTestCase {
    func test_zeroDistance_clampsToMin() {
        XCTAssertEqual(GhostCursorIntent.travelDurationMs(distance: 0), 320, accuracy: 0.001)
    }

    func test_shortDistance_scalesNormally() {
        // 320 + 100 * 0.18 = 338.0 (above floor; min clamp does not fire)
        XCTAssertEqual(GhostCursorIntent.travelDurationMs(distance: 100), 338.0, accuracy: 0.001)
    }

    func test_midDistance_scalesLinearly() {
        // 320 + 1500 * 0.18 = 320 + 270 = 590 → clamped to 560
        XCTAssertEqual(GhostCursorIntent.travelDurationMs(distance: 1500), 560, accuracy: 0.001)
    }

    func test_belowClampUpperBound() {
        // 320 + 1000 * 0.18 = 500 (within range)
        XCTAssertEqual(GhostCursorIntent.travelDurationMs(distance: 1000), 500, accuracy: 0.001)
    }

    func test_aboveClampUpperBound() {
        XCTAssertEqual(GhostCursorIntent.travelDurationMs(distance: 5000), 560, accuracy: 0.001)
    }
}
