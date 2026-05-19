import XCTest

final class MemoryGraphInspectorInboxTests: XCTestCase {
    func testMemoryGraphInspectorExposesInboxMetricAndPendingActions() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/MemoryGraphInspector.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("case inbox = \"Inbox\""))
        XCTAssertTrue(source.contains("title: \"Inbox\""))
        XCTAssertTrue(source.contains("value: \"\\(pendingAtoms.count)\""))
        XCTAssertTrue(source.contains("if atom.status == .pending"))
        XCTAssertTrue(source.contains("atomActionButton(title: \"Save\""))
        XCTAssertTrue(source.contains("MemoryReflectionProposalService("))
        XCTAssertTrue(source.contains("llmServiceProvider: llmServiceProvider"))
        XCTAssertTrue(source.contains(".approveAndPropose(atom.id)"))
        XCTAssertTrue(source.contains(".approveAndPropose(id)"))
        XCTAssertTrue(source.contains("atomActionButton(title: \"Reject\""))
        XCTAssertTrue(source.contains("MemoryLifecycleEngine(nodeStore: nodeStore).reject(atom.id)"))
        XCTAssertTrue(source.contains("atomActionButton(title: \"Forget\""))
        XCTAssertTrue(source.contains("MemoryLifecycleEngine(nodeStore: nodeStore).forget(atom.id)"))
    }

    func testMemoryGraphInspectorSourceQuoteUsesMessageIdAndEvidenceFallback() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/Nous/Views/MemoryGraphInspector.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("nodeStore.fetchMessage(id: sourceMessageId)"))
        XCTAssertTrue(source.contains("atom.evidenceQuote"))
    }
}
