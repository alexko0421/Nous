import Foundation

protocol BackgroundAIJobTelemetryRecording: AnyObject {
    func record(_ record: BackgroundAIJobRunRecord)
}

struct BackgroundAIJobTelemetrySummary: Equatable {
    let runCount: Int
    let completedCount: Int
    let skippedCount: Int
    let failedCount: Int
    let lastRun: BackgroundAIJobRunRecord?
}

final class BackgroundAIJobTelemetryStore: BackgroundAIJobTelemetryRecording {
    private let defaults: UserDefaults
    private let maxRecords: Int
    private let lock = NSLock()

    private enum Keys {
        static let recentRuns = "nous.backgroundAIJob.recentRuns"
    }

    init(defaults: UserDefaults = .standard, maxRecords: Int = 100) {
        self.defaults = defaults
        self.maxRecords = max(1, maxRecords)
    }

    func record(_ record: BackgroundAIJobRunRecord) {
        lock.lock()
        defer { lock.unlock() }

        var runs = loadRunsUnlocked()
        runs.append(record)
        runs.sort { $0.endedAt > $1.endedAt }
        if runs.count > maxRecords {
            runs = Array(runs.prefix(maxRecords))
        }
        saveRunsUnlocked(runs)
    }

    func record(
        jobId: BackgroundAIJobID,
        status: BackgroundAIJobStatus,
        startedAt: Date,
        endedAt: Date = Date(),
        inputCount: Int,
        outputCount: Int,
        detail: String?,
        costCents: Int? = nil
    ) {
        record(BackgroundAIJobRunRecord(
            id: UUID(),
            jobId: jobId,
            status: status,
            startedAt: startedAt,
            endedAt: endedAt,
            inputCount: max(0, inputCount),
            outputCount: max(0, outputCount),
            detail: detail,
            costCents: costCents
        ))
    }

    func recentRuns(limit: Int = 50) -> [BackgroundAIJobRunRecord] {
        lock.lock()
        defer { lock.unlock() }

        let runs = loadRunsUnlocked().sorted { $0.endedAt > $1.endedAt }
        return Array(runs.prefix(max(0, limit)))
    }

    func lastRun(for jobId: BackgroundAIJobID) -> BackgroundAIJobRunRecord? {
        recentRuns(limit: maxRecords).first { $0.jobId == jobId }
    }

    func summary(for jobId: BackgroundAIJobID) -> BackgroundAIJobTelemetrySummary {
        let runs = recentRuns(limit: maxRecords).filter { $0.jobId == jobId }
        return BackgroundAIJobTelemetrySummary(
            runCount: runs.count,
            completedCount: runs.filter { $0.status == .completed }.count,
            skippedCount: runs.filter { $0.status == .skipped }.count,
            failedCount: runs.filter { $0.status == .failed }.count,
            lastRun: runs.first
        )
    }

    private func loadRunsUnlocked() -> [BackgroundAIJobRunRecord] {
        guard let data = defaults.data(forKey: Keys.recentRuns),
              let runs = try? JSONDecoder().decode([BackgroundAIJobRunRecord].self, from: data) else {
            return []
        }
        return runs
    }

    private func saveRunsUnlocked(_ runs: [BackgroundAIJobRunRecord]) {
        guard let data = try? JSONEncoder().encode(runs) else { return }
        defaults.set(data, forKey: Keys.recentRuns)
    }
}
