import Foundation

final class GovernanceTelemetryStore {
    private let defaults: UserDefaults

    private enum Keys {
        static let lastPromptTrace = "nous.governance.lastPromptTrace"

        static func counter(_ counter: EvalCounter) -> String {
            "nous.governance.counter.\(counter.rawValue)"
        }

        static let memoryStorageSuppressedCount = "nous.governance.memoryStorageSuppressedCount"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastPromptTrace: PromptGovernanceTrace? {
        guard let data = defaults.data(forKey: Keys.lastPromptTrace) else { return nil }
        return try? JSONDecoder().decode(PromptGovernanceTrace.self, from: data)
    }

    func recordPromptTrace(_ trace: PromptGovernanceTrace) {
        if let data = try? JSONEncoder().encode(trace) {
            defaults.set(data, forKey: Keys.lastPromptTrace)
        }

        if trace.promptLayers.contains(where: { $0 != "anchor" && $0 != "core_safety_policy" }) {
            increment(.memoryUsefulness)
        }

        if trace.highRiskQueryDetected && !trace.safetyPolicyInvoked {
            increment(.safetyMissRate)
        }
    }

    func increment(_ counter: EvalCounter, by amount: Int = 1) {
        let key = Keys.counter(counter)
        defaults.set(defaults.integer(forKey: key) + amount, forKey: key)
    }

    func value(for counter: EvalCounter) -> Int {
        defaults.integer(forKey: Keys.counter(counter))
    }

    func recordMemoryStorageSuppressed() {
        defaults.set(defaults.integer(forKey: Keys.memoryStorageSuppressedCount) + 1, forKey: Keys.memoryStorageSuppressedCount)
    }

    func memoryStorageSuppressedCount() -> Int {
        defaults.integer(forKey: Keys.memoryStorageSuppressedCount)
    }
}
