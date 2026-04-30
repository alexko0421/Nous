import Foundation

protocol ShadowLearningStewardRunning {
    func runShadowLearning(userId: String, now: Date) async
}

extension ShadowLearningSteward: ShadowLearningStewardRunning {
    func runShadowLearning(userId: String, now: Date) async {
        _ = await runIfDue(userId: userId, now: now)
        _ = await consolidateIfDue(userId: userId, now: now)
    }
}

@MainActor
final class HeartbeatCoordinator {
    private let shadowLearningSteward: any ShadowLearningStewardRunning
    private let isEnabled: () -> Bool
    private let idleDelaySeconds: TimeInterval
    private var pendingShadowLearningTask: Task<Void, Never>?

    init(
        shadowLearningSteward: any ShadowLearningStewardRunning,
        isEnabled: @escaping () -> Bool,
        idleDelaySeconds: TimeInterval = 180
    ) {
        self.shadowLearningSteward = shadowLearningSteward
        self.isEnabled = isEnabled
        self.idleDelaySeconds = idleDelaySeconds
    }

    func scheduleShadowLearningAfterIdle(userId: String = "alex") {
        pendingShadowLearningTask?.cancel()
        pendingShadowLearningTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(idleDelaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard isEnabled() else { return }
            await shadowLearningSteward.runShadowLearning(userId: userId, now: Date())
        }
    }
}
