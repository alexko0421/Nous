import Foundation

#if DEBUG
/// Quick-mode ablation toggles backed by UserDefaults so they survive app launches
/// without code changes. Used to falsify the spec's two core assumptions:
/// (H1) anchor is neutral voice, mode addenda do skeleton work
/// (H2) memory pull does not cause mode-output convergence
///
/// To flip a flag from the macOS terminal:
///   defaults write com.nous.app.Nous AblationSkipAnchor -bool YES
///   defaults write com.nous.app.Nous AblationSkipModeAddendum -bool YES
///   defaults write com.nous.app.Nous AblationForceMemoryPolicy -string "lean"
/// To clear:
///   defaults delete com.nous.app.Nous AblationSkipAnchor
///
/// All read paths log to stdout on every quick-mode turn so Alex can confirm the
/// ablation actually fired.
enum DebugAblation {
    private static let skipAnchorKey = "AblationSkipAnchor"
    private static let skipModeAddendumKey = "AblationSkipModeAddendum"
    private static let forceMemoryPolicyKey = "AblationForceMemoryPolicy"

    /// True = drop anchor.md from the assembled prompt.
    static var skipAnchor: Bool {
        UserDefaults.standard.bool(forKey: skipAnchorKey)
    }

    /// True = drop the per-mode contextAddendum from the assembled prompt.
    static var skipModeAddendum: Bool {
        UserDefaults.standard.bool(forKey: skipModeAddendumKey)
    }

    /// One of: "full", "lean", "groundedBrainstorm", "projectOnly", "conversationOnly".
    /// nil = no override, agent's default policy is used.
    static var forceMemoryPolicyName: String? {
        UserDefaults.standard.string(forKey: forceMemoryPolicyKey)
    }

    /// Applies the forceMemoryPolicy override on top of the agent's default policy.
    /// Returns the original policy if no override is set or the override name is unknown.
    static func override(_ defaultPolicy: QuickActionMemoryPolicy) -> QuickActionMemoryPolicy {
        guard let name = forceMemoryPolicyName?.lowercased() else { return defaultPolicy }
        switch name {
        case "full":
            print("[DebugAblation] forceMemoryPolicy=full")
            return .full
        case "lean":
            print("[DebugAblation] forceMemoryPolicy=lean")
            return .lean
        case "groundedbrainstorm":
            print("[DebugAblation] forceMemoryPolicy=groundedBrainstorm")
            return .groundedBrainstorm
        case "projectonly":
            print("[DebugAblation] forceMemoryPolicy=projectOnly")
            return .fromStewardPreset(.projectOnly)
        case "conversationonly":
            print("[DebugAblation] forceMemoryPolicy=conversationOnly")
            return .fromStewardPreset(.conversationOnly)
        default:
            print("[DebugAblation] forceMemoryPolicy=\(name) UNKNOWN, falling through")
            return defaultPolicy
        }
    }

    /// Logs the active flags. Call once per quick-mode turn entry so Alex can confirm
    /// state without printing on every assembleContext call.
    static func logActiveFlags(context: String) {
        let parts: [String] = [
            skipAnchor ? "skipAnchor" : nil,
            skipModeAddendum ? "skipModeAddendum" : nil,
            forceMemoryPolicyName.map { "forceMemoryPolicy=\($0)" }
        ].compactMap { $0 }

        if !parts.isEmpty {
            print("[DebugAblation] [\(context)] \(parts.joined(separator: ", "))")
        }
    }
}
#endif
