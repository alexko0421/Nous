import XCTest
@testable import Nous

final class MemoryCuratorTests: XCTestCase {
    func testHardOptOutSuppressesPersistence() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "呢段唔好記住，我只是想讲出来。",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.role, .memoryCurator)
        XCTAssertEqual(assessment.lifecycle, .rejected)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.hardOptOut))
        XCTAssertTrue(assessment.reason.contains("opt-out"))
    }

    func testSensitiveMemoryRequiresConsentWhenBoundarySaysAskFirst() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "I had a panic attack yesterday.",
            boundaryLines: ["敏感內容先問"]
        )

        XCTAssertEqual(assessment.lifecycle, .consentRequired)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.sensitiveConsentRequired))
    }

    func testTemporaryErrandDoesNotBecomeStableMemory() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "tomorrow remind me to compare shoes after class",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .ephemeral)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
        XCTAssertTrue(assessment.reason.contains("temporary"))
    }

    func testContextUnclearProbeDoesNotPersist() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "context unclear",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .ephemeral)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
        XCTAssertTrue(assessment.reason.contains("low-signal"))
    }

    func testFinalRecallProbeDoesNotPersist() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "final probe: can you recall what this thread established?",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .ephemeral)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
        XCTAssertTrue(assessment.reason.contains("probe"))
    }

    func testStablePreferencePersistsAsPreference() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "Remember that I prefer concise implementation plans.",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .stable)
        XCTAssertEqual(assessment.kind, .preference)
        XCTAssertEqual(assessment.persistenceDecision, .persist)
    }

    func testStableDecisionWithTemporalWordStillPersists() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "今日我决定以后 prefer shorter plans when shipping.",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .stable)
        XCTAssertEqual(assessment.kind, .preference)
        XCTAssertEqual(assessment.persistenceDecision, .persist)
    }
}
