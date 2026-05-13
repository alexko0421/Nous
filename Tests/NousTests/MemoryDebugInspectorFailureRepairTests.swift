import XCTest

final class MemoryDebugInspectorFailureRepairTests: XCTestCase {
    func testFailureSkillRowsExposeRepairPRActionsAndStatus() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/MemoryDebugInspector.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Create Repair PR"))
        XCTAssertTrue(source.contains("Retry Repair PR"))
        XCTAssertTrue(source.contains("Mark Cancelled"))
        XCTAssertTrue(source.contains("cancelRepairRun"))
        XCTAssertTrue(source.contains("Repair PR"))
        XCTAssertTrue(source.contains("text: \"Activated\""))
        XCTAssertTrue(source.contains("candidate.repairKind != .observeOnly"))
        XCTAssertTrue(source.contains("FailureAutoRepairDraftService.checklistAllowsRepairDraft"))
        XCTAssertTrue(source.contains("creatingRepairCandidateIds"))
        XCTAssertTrue(source.contains("DispatchQueue.global(qos: .userInitiated).async"))
    }
}
