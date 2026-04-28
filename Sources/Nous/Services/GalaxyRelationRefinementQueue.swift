import Foundation

protocol GalaxyRelationRefining: AnyObject {
    func refineRelations(forNodeId nodeId: UUID) async throws
}

final class GalaxyRelationRefinementQueue {
    struct Configuration {
        var maxNodeRefinementsPerHour: Int = 30
        var maxRetryCount: Int = 1
        var minimumDelayBetweenJobs: TimeInterval = 1
        var startsAutomatically: Bool = true

        static let live = Configuration()
    }

    private struct Job {
        let nodeId: UUID
        var attempts: Int = 0
    }

    private enum NextJob {
        case job(Job)
        case wait(TimeInterval)
        case idle
    }

    private let refiner: GalaxyRelationRefining
    private let isEnabled: () -> Bool
    private let configuration: Configuration
    private let telemetry: GalaxyRelationTelemetry?
    private let lock = NSLock()
    private var pendingJobs: [Job] = []
    private var queuedNodeIds: Set<UUID> = []
    private var inFlightNodeIds: Set<UUID> = []
    private var startedAt: [Date] = []
    private var workerTask: Task<Void, Never>?
    private var workerToken: UUID?

    init(
        refiner: GalaxyRelationRefining,
        isEnabled: @escaping () -> Bool,
        configuration: Configuration = .live,
        telemetry: GalaxyRelationTelemetry? = nil
    ) {
        self.refiner = refiner
        self.isEnabled = isEnabled
        self.configuration = configuration
        self.telemetry = telemetry
    }

    deinit {
        workerTask?.cancel()
    }

    func enqueue(nodeId: UUID) {
        guard isEnabled() else {
            telemetry?.record(.queueDisabledDrop(1))
            return
        }

        let shouldStart = withLock {
            guard !queuedNodeIds.contains(nodeId), !inFlightNodeIds.contains(nodeId) else {
                telemetry?.record(.queueDeduped)
                return false
            }

            pendingJobs.append(Job(nodeId: nodeId))
            queuedNodeIds.insert(nodeId)
            telemetry?.record(.queueEnqueued)
            return configuration.startsAutomatically && workerTask == nil
        }

        if shouldStart {
            startWorkerIfNeeded()
        }
    }

    func pendingCountForTesting() -> Int {
        withLock { pendingJobs.count }
    }

    func drainForTesting() async {
        while !Task.isCancelled {
            switch nextJob() {
            case .job(let job):
                await run(job, delayAfterSuccess: false)
            case .wait, .idle:
                return
            }
        }
    }

    private func startWorkerIfNeeded() {
        withLock {
            guard workerTask == nil else { return }
            let token = UUID()
            workerToken = token
            workerTask = Task { [weak self] in
                guard let self else { return }
                await self.runWorker(token: token)
            }
        }
    }

    private func runWorker(token: UUID) async {
        while !Task.isCancelled {
            switch nextJob() {
            case .job(let job):
                await run(job, delayAfterSuccess: true)
            case .wait(let seconds):
                let nanoseconds = UInt64(max(seconds, 1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            case .idle:
                stopWorker(token: token)
                return
            }
        }
        stopWorker(token: token)
    }

    private func run(_ job: Job, delayAfterSuccess: Bool) async {
        do {
            try await refiner.refineRelations(forNodeId: job.nodeId)
            finish(job, shouldRetry: false)
            if delayAfterSuccess, configuration.minimumDelayBetweenJobs > 0 {
                let nanoseconds = UInt64(configuration.minimumDelayBetweenJobs * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        } catch {
            let shouldRetry = job.attempts < configuration.maxRetryCount
            finish(job, shouldRetry: shouldRetry, recordPermanentFailure: !shouldRetry)
        }
    }

    private func nextJob() -> NextJob {
        withLock {
            guard isEnabled() else {
                telemetry?.record(.queueDisabledDrop(pendingJobs.count))
                pendingJobs.removeAll()
                queuedNodeIds.removeAll()
                return .idle
            }

            guard !pendingJobs.isEmpty else { return .idle }

            let now = Date()
            pruneBudgetWindow(now: now)

            guard configuration.maxNodeRefinementsPerHour <= 0 ||
                    startedAt.count < configuration.maxNodeRefinementsPerHour else {
                let oldest = startedAt.min() ?? now
                let wait = oldest.addingTimeInterval(3600).timeIntervalSince(now)
                telemetry?.record(.queueBudgetWait)
                return .wait(wait)
            }

            let job = pendingJobs.removeFirst()
            queuedNodeIds.remove(job.nodeId)
            inFlightNodeIds.insert(job.nodeId)
            startedAt.append(now)
            telemetry?.record(.queueStarted)
            return .job(job)
        }
    }

    private func finish(
        _ job: Job,
        shouldRetry: Bool,
        recordPermanentFailure: Bool = false
    ) {
        withLock {
            inFlightNodeIds.remove(job.nodeId)

            guard shouldRetry, isEnabled() else { return }
            guard !queuedNodeIds.contains(job.nodeId), !inFlightNodeIds.contains(job.nodeId) else {
                return
            }

            var retry = job
            retry.attempts += 1
            pendingJobs.append(retry)
            queuedNodeIds.insert(retry.nodeId)
            telemetry?.record(.queueRetry)
        }

        if recordPermanentFailure {
            telemetry?.record(.queuePermanentFailure)
        }
    }

    private func pruneBudgetWindow(now: Date) {
        startedAt = startedAt.filter { now.timeIntervalSince($0) < 3600 }
    }

    private func stopWorker(token: UUID) {
        withLock {
            guard workerToken == token else { return }
            workerTask = nil
            workerToken = nil
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
