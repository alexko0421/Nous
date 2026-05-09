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

    func testEnglishHardOptOutWithDurableSignalSuppressesPersistence() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "Please don't remember that I prefer verbose implementation plans.",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .rejected)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.hardOptOut))
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
        XCTAssertTrue(assessment.reason.contains("probe"))
    }

    func testLowSignalChatDoesNotPersist() {
        let curator = MemoryCurator()

        for text in ["ok thanks, makes sense", "继续扫继续扫"] {
            let assessment = curator.assess(
                latestUserText: text,
                boundaryLines: []
            )

            XCTAssertEqual(assessment.lifecycle, .ephemeral, text)
            XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified), text)
            XCTAssertTrue(assessment.reason.contains("low-signal"), text)
        }
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

    func testMemoryStatusProbeWithRememberWordDoesNotPersist() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "memory probe: 你记住了吗？",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .ephemeral)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
        XCTAssertTrue(assessment.reason.contains("memory-status probe"))
    }

    func testPunctuatedMemoryStatusProbeDoesNotPersist() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "memory-probe: 你記住咗咩？",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .ephemeral)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
        XCTAssertTrue(assessment.reason.contains("memory-status probe"))
    }

    func testMemoryStatusProbeWithoutQuestionMarkDoesNotPersist() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "memory-probe: 记住",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .ephemeral)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
        XCTAssertTrue(assessment.reason.contains("memory-status probe"))
    }

    func testMemoryProbeWithNewStablePreferenceStillPersists() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "memory-probe: remember that I prefer concise implementation plans.",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .stable)
        XCTAssertEqual(assessment.kind, .preference)
        XCTAssertEqual(assessment.persistenceDecision, .persist)
    }

    func testRecallProbeMentioningPreferenceWithoutNewFactDoesNotPersist() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "recall probe: what is my preference?",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .ephemeral)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
        XCTAssertTrue(assessment.reason.contains("probe"))
    }

    func testRecallProbeMentioningCorrectionWithoutNewFactDoesNotPersist() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "recall probe: what correction did I make?",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .ephemeral)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
        XCTAssertTrue(assessment.reason.contains("probe"))
    }

    func testMetaMemoryQuestionWithoutNewFactDoesNotPersist() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "Should Nous memory save this?",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .ephemeral)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
        XCTAssertTrue(assessment.reason.contains("probe"))
    }

    func testMetaMemoryQuestionWithoutQuestionMarkDoesNotPersist() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "Should Nous memory save this",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .ephemeral)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
        XCTAssertTrue(assessment.reason.contains("probe"))
    }

    func testChineseMetaMemoryQuestionWithoutQuestionMarkDoesNotPersist() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "應唔應該記住呢個",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .ephemeral)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
        XCTAssertTrue(assessment.reason.contains("probe"))
    }

    func testFutureHorizonQuestionWithoutNewFactDoesNotPersist() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "Going forward, should you remember this?",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .ephemeral)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
        XCTAssertTrue(assessment.reason.contains("probe"))
    }

    func testMemoryProbeWithExplicitCorrectionStillPersists() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "memory-probe: Correction: the project baseline should stay mock-only for QA.",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .stable)
        XCTAssertEqual(assessment.persistenceDecision, .persist)
    }

    func testPunctuatedContextUnclearProbeDoesNotPersist() {
        let curator = MemoryCurator()

        let assessment = curator.assess(
            latestUserText: "context-unclear",
            boundaryLines: []
        )

        XCTAssertEqual(assessment.lifecycle, .ephemeral)
        XCTAssertEqual(assessment.persistenceDecision, .suppress(.unspecified))
        XCTAssertTrue(assessment.reason.contains("low-signal"))
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
