import Foundation

/// Runtime feature flags backed by `UserDefaults`. Unlike `DebugAblation`
/// (which is `#if DEBUG` and exists to falsify hypotheses), feature flags
/// stay alive in release builds so a regression caught after dogfood can be
/// reversed with one terminal command instead of a code revert.
///
/// Flip from the macOS terminal:
///   defaults write com.nous.app.Nous AtomCardsEnabled -bool YES
/// Clear:
///   defaults delete com.nous.app.Nous AtomCardsEnabled
enum FeatureFlags {
    private static let atomCardsKey = "AtomCardsEnabled"

    /// Phase 1B: when true, the chat citation chip area renders atom-level
    /// `CorpusAtomCardListView` (own-corpus retrieval). When false, the legacy
    /// `RAGCitationView` keeps rendering conversation-level citations.
    /// Default flipped to true 2026-05-10 (Phase 1D dogfood ship). Users who
    /// previously opted out via `defaults write … AtomCardsEnabled -bool NO`
    /// keep that override; users who never touched the key now see atom cards.
    static var atomCardsEnabled: Bool {
        if UserDefaults.standard.object(forKey: atomCardsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: atomCardsKey)
    }

    /// Test-only override hook. Tests set this to drive cascade behavior
    /// without touching `UserDefaults` (which leaks across test cases).
    /// Production code reads `atomCardsEnabled`; never set this outside tests.
    static var atomCardsEnabledOverride: Bool?

    /// Resolved value the app should consume. Override wins when set.
    static var resolvedAtomCardsEnabled: Bool {
        atomCardsEnabledOverride ?? atomCardsEnabled
    }
}
