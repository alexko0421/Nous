import XCTest
@testable import Nous

final class HarnessHealthTests: XCTestCase {
    func testClassifiesAnchorAsProtectedFileChange() {
        let result = HarnessChangeClassifier.classify(
            changedPaths: ["Sources/Nous/Resources/anchor.md"],
            rootSwiftFiles: []
        )

        XCTAssertTrue(result.requiresFullGate)
        XCTAssertTrue(result.hasBlockingIssues)
        XCTAssertTrue(result.findings.contains(.protectedAnchorChanged))
    }

    func testClassifiesRootSwiftOrphanAsBlockingIssue() {
        let result = HarnessChangeClassifier.classify(
            changedPaths: [],
            rootSwiftFiles: ["Sources/Nous/Temporary.swift"]
        )

        XCTAssertTrue(result.hasBlockingIssues)
        XCTAssertTrue(result.findings.contains(.rootSwiftOrphan))
    }

    func testPromptModelAndMemoryChangesRequireFullGate() {
        let result = HarnessChangeClassifier.classify(
            changedPaths: [
                "Sources/Nous/Services/PromptContextAssembler.swift",
                "Sources/Nous/Services/LLMService.swift",
                "Sources/Nous/Services/MemoryProjectionService.swift"
            ],
            rootSwiftFiles: []
        )

        XCTAssertTrue(result.requiresFullGate)
        XCTAssertFalse(result.hasBlockingIssues)
        XCTAssertTrue(result.findings.contains(.promptSurfaceChanged))
        XCTAssertTrue(result.findings.contains(.modelSurfaceChanged))
        XCTAssertTrue(result.findings.contains(.memorySurfaceChanged))
    }

    func testSwiftSourceSetChangesRequireFullGate() {
        let result = HarnessChangeClassifier.classify(
            changedPaths: [
                "Sources/Nous/Models/NewHarnessModel.swift",
                "Tests/NousTests/NewHarnessModelTests.swift"
            ],
            rootSwiftFiles: []
        )

        XCTAssertTrue(result.requiresFullGate)
        XCTAssertFalse(result.hasBlockingIssues)
        XCTAssertTrue(result.findings.contains(.sourceSetChanged))
    }

    func testClassifierTracksUnclassifiedCurrentChanges() {
        let result = HarnessChangeClassifier.classify(
            changedPaths: ["docs/agentic-engineering-workflow.md"],
            rootSwiftFiles: [],
            changeSignature: "docs"
        )

        XCTAssertFalse(result.requiresFullGate)
        XCTAssertFalse(result.hasBlockingIssues)
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertTrue(result.hasCurrentChanges)
        XCTAssertEqual(result.changeSignature, "docs")
    }

    func testHarnessSnapshotSummarizesFailedRecentRuns() {
        let recentRun = HarnessRunRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!,
            mode: .quick,
            status: .failed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 12),
            findings: [.rootSwiftOrphan],
            detail: "Root Swift files found."
        )

        let snapshot = HarnessHealthSnapshot(
            recentRuns: [recentRun],
            changeClassification: HarnessChangeClassification(
                findings: [.rootSwiftOrphan],
                rootSwiftFiles: ["Sources/Nous/Temporary.swift"]
            )
        )

        XCTAssertEqual(snapshot.buildStatus, .failed)
        XCTAssertEqual(snapshot.statusText, "Quick gate failed")
        XCTAssertTrue(snapshot.founderLoopSummary.contains("Fix quality gates before closing work."))
    }

    func testUnclassifiedChangesNeedFreshQuickGate() {
        let staleQuickRun = HarnessRunRecord(
            mode: .quick,
            status: .passed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            detail: "Quick gate passed.",
            changeSignature: "old"
        )
        let snapshot = HarnessHealthSnapshot(
            recentRuns: [staleQuickRun],
            changeClassification: HarnessChangeClassification(
                changeSignature: "new",
                hasCurrentChanges: true
            )
        )

        XCTAssertEqual(snapshot.buildStatus, .needsQuickGate)
        XCTAssertEqual(snapshot.statusText, "Quick gate needed")
        XCTAssertTrue(snapshot.founderLoopSummary.contains("Run the quick gate before closing work."))
    }

    func testMatchingQuickSignatureCoversUnclassifiedChanges() {
        let freshQuickRun = HarnessRunRecord(
            mode: .quick,
            status: .passed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            detail: "Quick gate passed.",
            changeSignature: "same"
        )
        let snapshot = HarnessHealthSnapshot(
            recentRuns: [freshQuickRun],
            changeClassification: HarnessChangeClassification(
                changeSignature: "same",
                hasCurrentChanges: true
            )
        )

        XCTAssertEqual(snapshot.buildStatus, .passed)
        XCTAssertEqual(snapshot.statusText, "Quick gate passed")
    }

    func testFullGateMustMatchCurrentChangeSignature() {
        let staleFullRun = HarnessRunRecord(
            mode: .full,
            status: .passed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            findings: [.sourceSetChanged],
            detail: "Full gate passed.",
            changeSignature: "old"
        )
        let snapshot = HarnessHealthSnapshot(
            recentRuns: [staleFullRun],
            changeClassification: HarnessChangeClassification(
                findings: [.sourceSetChanged],
                changeSignature: "new"
            )
        )

        XCTAssertEqual(snapshot.buildStatus, .needsFullGate)
        XCTAssertEqual(snapshot.statusText, "Full gate needed")
    }

    func testMatchingFullGateSignatureCoversCurrentRiskyChanges() {
        let freshFullRun = HarnessRunRecord(
            mode: .full,
            status: .passed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            findings: [.sourceSetChanged],
            detail: "Full gate passed.",
            changeSignature: "same"
        )
        let snapshot = HarnessHealthSnapshot(
            recentRuns: [freshFullRun],
            changeClassification: HarnessChangeClassification(
                findings: [.sourceSetChanged],
                changeSignature: "same"
            )
        )

        XCTAssertEqual(snapshot.buildStatus, .passed)
        XCTAssertEqual(snapshot.statusText, "Full gate passed")
    }

    func testLegacyFullGateWithoutSignatureDoesNotCoverCurrentRiskyChanges() {
        let legacyFullRun = HarnessRunRecord(
            mode: .full,
            status: .passed,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            findings: [.sourceSetChanged],
            detail: "Full gate passed."
        )
        let snapshot = HarnessHealthSnapshot(
            recentRuns: [legacyFullRun],
            changeClassification: HarnessChangeClassification(
                findings: [.sourceSetChanged],
                changeSignature: "current"
            )
        )

        XCTAssertEqual(snapshot.buildStatus, .needsFullGate)
    }

    func testSycophancyTrendAcceptsBooleanHistoryRows() throws {
        let repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let historyURL = repoURL.appendingPathComponent("results/sycophancy/history.jsonl")
        try FileManager.default.createDirectory(
            at: historyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let history = """
        {"run_id":"old","passed":true}
        {"run_id":"latest","passed":true}
        {"run_id":"latest","passed":false}
        """
        try history.write(to: historyURL, atomically: true, encoding: .utf8)

        let snapshot = RuntimeHarnessService(repoURL: repoURL).loadSnapshot()

        XCTAssertEqual(snapshot.sycophancyFixtureTrend, "1/2 sycophancy fixtures passing")
    }
}
