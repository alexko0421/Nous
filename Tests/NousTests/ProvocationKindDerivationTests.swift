import XCTest
@testable import Nous

final class ProvocationKindDerivationTests: XCTestCase {

    func testNeutralWhenShouldProvokeFalse() {
        let verdict = JudgeVerdict(
            tensionExists: true, userState: .deciding,
            shouldProvoke: false, entryId: "E1",
            reason: "tension but venting elsewhere", inferredMode: .companion
        )
        XCTAssertEqual(
            ChatViewModel.deriveProvocationKind(verdict: verdict, contradictionCandidateIds: ["E1"]),
            .neutral
        )
    }

    func testContradictionWhenCitedEntryWasFlaggedCandidate() {
        let verdict = JudgeVerdict(
            tensionExists: true, userState: .deciding,
            shouldProvoke: true, entryId: "E1",
            reason: "cuts against earlier decision", inferredMode: .strategist
        )
        XCTAssertEqual(
            ChatViewModel.deriveProvocationKind(verdict: verdict, contradictionCandidateIds: ["E1", "E2"]),
            .contradiction
        )
    }

    func testSparkWhenProvokingButCitedEntryWasNotFlagged() {
        let verdict = JudgeVerdict(
            tensionExists: true, userState: .exploring,
            shouldProvoke: true, entryId: "E9",
            reason: "latent connection worth surfacing", inferredMode: .strategist
        )
        XCTAssertEqual(
            ChatViewModel.deriveProvocationKind(verdict: verdict, contradictionCandidateIds: ["E1", "E2"]),
            .spark
        )
    }

    func testSparkWhenProvokingWithoutEntryId() {
        let verdict = JudgeVerdict(
            tensionExists: true, userState: .deciding,
            shouldProvoke: true, entryId: nil,
            reason: "schema violation but flagged anyway", inferredMode: .strategist
        )
        XCTAssertEqual(
            ChatViewModel.deriveProvocationKind(verdict: verdict, contradictionCandidateIds: []),
            .spark
        )
    }
}
