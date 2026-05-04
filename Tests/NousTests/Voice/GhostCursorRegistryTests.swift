import XCTest
@testable import Nous

@MainActor
final class GhostCursorRegistryTests: XCTestCase {
    func test_centerReturnsMidpointOfRegisteredFrame() {
        let r = GhostCursorRegistry()
        r.update(id: "tab_galaxy", frame: CGRect(x: 100, y: 200, width: 40, height: 40))
        XCTAssertEqual(r.center(for: "tab_galaxy"), CGPoint(x: 120, y: 220))
        XCTAssertNil(r.center(for: "nonexistent"))
    }

    func test_pulseGeneratesDistinctTriggersOnEachCall() {
        let r = GhostCursorRegistry()
        XCTAssertNil(r.pulseTrigger(for: "x"))
        r.pulse(id: "x")
        let first = r.pulseTrigger(for: "x")
        XCTAssertNotNil(first)
        r.pulse(id: "x")
        XCTAssertNotEqual(first, r.pulseTrigger(for: "x"))
    }

    func test_removeClearsBothFrameAndPulse() {
        let r = GhostCursorRegistry()
        r.update(id: "x", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        r.pulse(id: "x")
        r.remove(id: "x")
        XCTAssertNil(r.frame(for: "x"))
        XCTAssertNil(r.pulseTrigger(for: "x"))
    }
}
