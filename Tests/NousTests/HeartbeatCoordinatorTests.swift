import XCTest
@testable import Nous

@MainActor
final class HeartbeatCoordinatorTests: XCTestCase {
    func testScheduleCancelsPriorPendingRun() async {
        let steward = CountingShadowLearningSteward()
        let coordinator = HeartbeatCoordinator(
            shadowLearningSteward: steward,
            isEnabled: { true },
            idleDelaySeconds: 0.05
        )

        coordinator.scheduleShadowLearningAfterIdle()
        coordinator.scheduleShadowLearningAfterIdle()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let runCount = await steward.currentRunCount()
        XCTAssertEqual(runCount, 1)
    }

    func testDisabledCoordinatorDoesNotRun() async {
        let steward = CountingShadowLearningSteward()
        let coordinator = HeartbeatCoordinator(
            shadowLearningSteward: steward,
            isEnabled: { false },
            idleDelaySeconds: 0.01
        )

        coordinator.scheduleShadowLearningAfterIdle()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let runCount = await steward.currentRunCount()
        XCTAssertEqual(runCount, 0)
    }
}

private actor CountingShadowLearningSteward: ShadowLearningStewardRunning {
    private var runCount = 0

    func runShadowLearning(userId: String, now: Date) async {
        runCount += 1
    }

    func currentRunCount() -> Int {
        runCount
    }
}
