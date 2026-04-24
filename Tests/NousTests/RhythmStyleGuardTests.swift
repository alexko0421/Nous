import XCTest

/// Structural regression guard for Sources/Nous/Resources/anchor.md.
///
/// Does NOT assert rhythm quality — that is validated by the before/after
/// corpus run and by real-session subjective read. This test only asserts
/// that specific structural anchors added in the 2026-04-24 chat-rhythm
/// Phase 1 work do not silently disappear during future edits.
///
/// Anchors asserted:
///   1. `# RHYTHM` section exists and is positioned immediately after
///      the `# STYLE RULES` section.
///   2. The "Reactive beat ≠ filler" disambiguation substring is present.
///   3. The "每个 reply 最多一个问号" rule from the 2026-04-21 spec is
///      still present (guard against accidental deletion during RHYTHM edit).
///   4. The reconciliation-with-stoic-grounding clause is present.
final class RhythmStyleGuardTests: XCTestCase {

    /// Resolves anchor.md via the test file's own source path so this
    /// test does not depend on the file being bundled into NousTests.
    private func loadAnchor() throws -> String {
        let thisFile = URL(fileURLWithPath: #file)
        // Tests/NousTests/RhythmStyleGuardTests.swift -> repo root
        let repoRoot = thisFile
            .deletingLastPathComponent()  // NousTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let anchorURL = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("Nous")
            .appendingPathComponent("Resources")
            .appendingPathComponent("anchor.md")
        return try String(contentsOf: anchorURL, encoding: .utf8)
    }

    func testRhythmSectionExists() throws {
        let anchor = try loadAnchor()
        XCTAssertTrue(
            anchor.contains("# RHYTHM"),
            "anchor.md is missing the '# RHYTHM' section heading. " +
            "See docs/superpowers/specs/2026-04-24-chat-rhythm-design.md §4.1."
        )
    }

    func testRhythmSectionFollowsStyleRules() throws {
        let anchor = try loadAnchor()
        guard
            let styleRange = anchor.range(of: "# STYLE RULES"),
            let rhythmRange = anchor.range(of: "# RHYTHM")
        else {
            XCTFail("Both '# STYLE RULES' and '# RHYTHM' headings must exist.")
            return
        }
        XCTAssertLessThan(
            styleRange.lowerBound, rhythmRange.lowerBound,
            "'# RHYTHM' must appear AFTER '# STYLE RULES' per spec §4.1."
        )

        // Additionally: no other top-level heading should sit between them.
        let between = anchor[styleRange.upperBound..<rhythmRange.lowerBound]
        let interveningTopHeadings = between
            .split(separator: "\n")
            .filter { $0.hasPrefix("# ") }
        XCTAssertTrue(
            interveningTopHeadings.isEmpty,
            "No other top-level section should come between STYLE RULES and " +
            "RHYTHM. Found: \(interveningTopHeadings)"
        )
    }

    func testReactiveBeatDisambiguationPresent() throws {
        let anchor = try loadAnchor()
        XCTAssertTrue(
            anchor.contains("Reactive beat ≠ filler"),
            "The 'Reactive beat ≠ filler' disambiguation must stay in the " +
            "RHYTHM section so Nous does not treat reactive beats as filler. " +
            "See spec §4.1 and §4.4 step 2."
        )
    }

    func testMaxOneQuestionMarkRuleStillPresent() throws {
        let anchor = try loadAnchor()
        XCTAssertTrue(
            anchor.contains("每个 reply 最多一个问号"),
            "The max-1-? rule (from 2026-04-21 naturalness spec) must not " +
            "be deleted during the RHYTHM edit. See spec §4.5."
        )
    }

    func testStoicGroundingReconciliationClausePresent() throws {
        let anchor = try loadAnchor()
        XCTAssertTrue(
            anchor.contains("stoic grounding policy"),
            "The reconciliation clause referencing stoic grounding policy " +
            "must live inside the RHYTHM section itself, not only in the " +
            "design spec. See spec §4.6."
        )
    }
}
