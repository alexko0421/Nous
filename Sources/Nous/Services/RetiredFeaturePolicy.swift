import Foundation

/// Product-retirement guardrails for surfaces Alex has explicitly shut off.
///
/// These are intentionally not UserDefaults-backed feature flags. Re-enabling
/// Project or Galaxy should require a deliberate code review, not a hidden
/// terminal default or stale UI path.
enum RetiredFeaturePolicy {
    static let galaxySurfacesEnabled = false

    static var projectSurfacesEnabled: Bool {
        projectSurfacesEnabledOverride ?? false
    }

    static var galaxyBackgroundWorkEnabled: Bool {
        galaxyBackgroundWorkEnabledOverride ?? false
    }

    static var projectSurfacesEnabledOverride: Bool?
    static var galaxyBackgroundWorkEnabledOverride: Bool?
}
