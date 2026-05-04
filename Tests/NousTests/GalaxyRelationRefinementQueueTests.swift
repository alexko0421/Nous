import XCTest
@testable import Nous

final class GalaxyRelationRefinementQueueTests: XCTestCase {
    func testQueueDeduplicatesPendingNode() async {
        let refiner = RecordingRelationRefiner()
        let telemetry = GalaxyRelationTelemetry()
        let queue = GalaxyRelationRefinementQueue(
            refiner: refiner,
            isEnabled: { true },
            configuration: GalaxyRelationRefinementQueue.Configuration(
                maxNodeRefinementsPerHour: 10,
                maxRetryCount: 0,
                minimumDelayBetweenJobs: 0,
                startsAutomatically: false
            ),
            telemetry: telemetry
        )
        let nodeId = UUID()

        queue.enqueue(nodeId: nodeId)
        queue.enqueue(nodeId: nodeId)
        await queue.drainForTesting()

        XCTAssertEqual(refiner.recordedCalls(), [nodeId])
        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.queueEnqueuedCount, 1)
        XCTAssertEqual(snapshot.queueDedupedCount, 1)
        XCTAssertEqual(snapshot.queueStartedCount, 1)
    }

    func testQueueStopsAtHourlyBudget() async {
        let refiner = RecordingRelationRefiner()
        let telemetry = GalaxyRelationTelemetry()
        let queue = GalaxyRelationRefinementQueue(
            refiner: refiner,
            isEnabled: { true },
            configuration: GalaxyRelationRefinementQueue.Configuration(
                maxNodeRefinementsPerHour: 1,
                maxRetryCount: 0,
                minimumDelayBetweenJobs: 0,
                startsAutomatically: false
            ),
            telemetry: telemetry
        )
        let first = UUID()
        let second = UUID()

        queue.enqueue(nodeId: first)
        queue.enqueue(nodeId: second)
        await queue.drainForTesting()

        XCTAssertEqual(refiner.recordedCalls(), [first])
        XCTAssertEqual(queue.pendingCountForTesting(), 1)
        XCTAssertEqual(telemetry.snapshot().queueBudgetWaitCount, 1)
    }

    func testQueueRetriesOnceAfterFailure() async {
        let refiner = RecordingRelationRefiner(failuresBeforeSuccess: 1)
        let telemetry = GalaxyRelationTelemetry()
        let queue = GalaxyRelationRefinementQueue(
            refiner: refiner,
            isEnabled: { true },
            configuration: GalaxyRelationRefinementQueue.Configuration(
                maxNodeRefinementsPerHour: 10,
                maxRetryCount: 1,
                minimumDelayBetweenJobs: 0,
                startsAutomatically: false
            ),
            telemetry: telemetry
        )
        let nodeId = UUID()

        queue.enqueue(nodeId: nodeId)
        await queue.drainForTesting()

        XCTAssertEqual(refiner.recordedCalls(), [nodeId, nodeId])
        XCTAssertEqual(queue.pendingCountForTesting(), 0)
        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.queueRetryCount, 1)
        XCTAssertEqual(snapshot.queuePermanentFailureCount, 0)
    }

    func testQueueTelemetryTracksPermanentFailure() async {
        let refiner = RecordingRelationRefiner(failuresBeforeSuccess: 1)
        let telemetry = GalaxyRelationTelemetry()
        let queue = GalaxyRelationRefinementQueue(
            refiner: refiner,
            isEnabled: { true },
            configuration: GalaxyRelationRefinementQueue.Configuration(
                maxNodeRefinementsPerHour: 10,
                maxRetryCount: 0,
                minimumDelayBetweenJobs: 0,
                startsAutomatically: false
            ),
            telemetry: telemetry
        )

        queue.enqueue(nodeId: UUID())
        await queue.drainForTesting()

        XCTAssertEqual(telemetry.snapshot().queuePermanentFailureCount, 1)
    }
}

private final class RecordingRelationRefiner: GalaxyRelationRefining {
    private let lock = NSLock()
    private var calls: [UUID] = []
    private var failuresBeforeSuccess: Int

    init(failuresBeforeSuccess: Int = 0) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func refineRelations(forNodeId nodeId: UUID) async throws {
        lock.lock()
        calls.append(nodeId)
        let shouldFail = failuresBeforeSuccess > 0
        if shouldFail {
            failuresBeforeSuccess -= 1
        }
        lock.unlock()

        if shouldFail {
            throw RecordingRelationRefinerError.failed
        }
    }

    func recordedCalls() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private enum RecordingRelationRefinerError: Error {
    case failed
}
