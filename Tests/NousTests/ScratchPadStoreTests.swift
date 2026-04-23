import XCTest
@testable import Nous

@MainActor
final class ScratchPadStoreTests: XCTestCase {

    private var defaultsSuite: UserDefaults!

    override func setUp() {
        super.setUp()
        let suiteName = "ScratchPadStoreTests.\(UUID().uuidString)"
        defaultsSuite = UserDefaults(suiteName: suiteName)!
        defaultsSuite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaultsSuite = nil
        super.tearDown()
    }

    /// Build a store pre-activated on a fresh conversation id. Existing tests predate the
    /// per-conversation split and target the active-conversation surface, so this keeps
    /// them unchanged.
    private func makeStore(conversationId: UUID = UUID()) -> ScratchPadStore {
        let store = ScratchPadStore(defaults: defaultsSuite)
        store.activate(conversationId: conversationId)
        return store
    }

    private func summary(_ markdown: String, at date: Date = Date()) -> ScratchSummary {
        ScratchSummary(markdown: markdown, generatedAt: date, sourceMessageId: UUID())
    }

    // MARK: - Ingest

    func testIngestStoresLatestSummaryWhenContentPresent() {
        let store = makeStore()
        let s = summary("# Title\n\nBody")
        store.ingest(summary: s)
        XCTAssertEqual(store.latestSummary, s)
    }

    func testIngestLaterSummaryReplacesLatest() {
        let store = makeStore()
        let first = summary("# First", at: Date(timeIntervalSince1970: 1000))
        let second = summary("# Second", at: Date(timeIntervalSince1970: 2000))
        store.ingest(summary: first)
        store.ingest(summary: second)
        XCTAssertEqual(store.latestSummary, second)
    }

    // MARK: - Load logic

    func testOnPanelOpenedWithEmptyContentLoadsSummarySilently() {
        let store = makeStore()
        let s = summary("# Hello")
        store.ingest(summary: s)

        store.onPanelOpened()

        XCTAssertEqual(store.currentContent, "# Hello")
        XCTAssertEqual(store.baseSnapshot, "# Hello")
        XCTAssertEqual(store.contentBaseGeneratedAt, s.generatedAt)
        XCTAssertNil(store.pendingOverwrite)
        XCTAssertFalse(store.isDirty)
    }

    func testOnPanelOpenedWithFreeTypedContentAndFirstSummaryQueuesOverwrite() {
        let store = makeStore()
        store.updateContent("my own notes")   // no summary yet; free-typing
        XCTAssertFalse(store.isDirty)        // zero-base while no summary

        let s = summary("# Auto")
        store.ingest(summary: s)
        store.onPanelOpened()

        XCTAssertEqual(store.currentContent, "my own notes")
        XCTAssertEqual(store.pendingOverwrite, s)
    }

    func testOnPanelOpenedSameBaseReloadIsNoOp() {
        let store = makeStore()
        let s = summary("# A")
        store.ingest(summary: s)
        store.onPanelOpened()

        store.updateContent("# A — with my edits")
        XCTAssertTrue(store.isDirty)

        store.onPanelOpened()   // same latest, already based on it
        XCTAssertEqual(store.currentContent, "# A — with my edits")
        XCTAssertNil(store.pendingOverwrite)
    }

    func testOnPanelOpenedNewerSummaryWithCleanContentOverwritesSilently() {
        let store = makeStore()
        let first = summary("# First", at: Date(timeIntervalSince1970: 1))
        store.ingest(summary: first)
        store.onPanelOpened()

        let second = summary("# Second", at: Date(timeIntervalSince1970: 2))
        store.ingest(summary: second)
        store.onPanelOpened()

        XCTAssertEqual(store.currentContent, "# Second")
        XCTAssertEqual(store.baseSnapshot, "# Second")
        XCTAssertEqual(store.contentBaseGeneratedAt, second.generatedAt)
        XCTAssertNil(store.pendingOverwrite)
    }

    func testOnPanelOpenedNewerSummaryWithDirtyContentQueuesOverwrite() {
        let store = makeStore()
        let first = summary("# First", at: Date(timeIntervalSince1970: 1))
        store.ingest(summary: first)
        store.onPanelOpened()

        store.updateContent("# First — edited")
        XCTAssertTrue(store.isDirty)

        let second = summary("# Second", at: Date(timeIntervalSince1970: 2))
        store.ingest(summary: second)
        store.onPanelOpened()

        XCTAssertEqual(store.currentContent, "# First — edited")  // untouched
        XCTAssertEqual(store.pendingOverwrite, second)
    }

    // MARK: - Accept / Reject

    func testAcceptPendingOverwriteApplies() {
        let store = makeStore()
        store.ingest(summary: summary("# A"))
        store.onPanelOpened()
        store.updateContent("# A — edits")
        let next = summary("# B", at: Date(timeIntervalSince1970: 99))
        store.ingest(summary: next)
        store.onPanelOpened()

        store.acceptPendingOverwrite()

        XCTAssertEqual(store.currentContent, "# B")
        XCTAssertEqual(store.baseSnapshot, "# B")
        XCTAssertEqual(store.contentBaseGeneratedAt, next.generatedAt)
        XCTAssertNil(store.pendingOverwrite)
        XCTAssertFalse(store.isDirty)
    }

    func testRejectPendingOverwriteLeavesStateUntouched() {
        let store = makeStore()
        store.ingest(summary: summary("# A"))
        store.onPanelOpened()
        store.updateContent("# A — edits")
        let next = summary("# B", at: Date(timeIntervalSince1970: 99))
        store.ingest(summary: next)
        store.onPanelOpened()

        store.rejectPendingOverwrite()

        XCTAssertEqual(store.currentContent, "# A — edits")
        XCTAssertEqual(store.baseSnapshot, "# A")
        XCTAssertNil(store.pendingOverwrite)
    }

    // MARK: - Download

    func testMarkDownloadedResetsDirtyAgainstCurrentContent() {
        let store = makeStore()
        store.ingest(summary: summary("# A"))
        store.onPanelOpened()
        store.updateContent("# A — edits")
        XCTAssertTrue(store.isDirty)

        store.markDownloaded()

        XCTAssertEqual(store.baseSnapshot, "# A — edits")
        XCTAssertFalse(store.isDirty)
    }

    // MARK: - Per-conversation isolation

    func testSummaryFromOneConversationDoesNotLeakIntoAnother() {
        let convA = UUID()
        let convB = UUID()
        let store = ScratchPadStore(defaults: defaultsSuite)

        // A receives a summary.
        store.activate(conversationId: convA)
        store.ingest(summary: summary("# A only"))
        store.onPanelOpened()
        XCTAssertEqual(store.currentContent, "# A only")

        // Switch to B — should be a clean slate.
        store.activate(conversationId: convB)
        XCTAssertNil(store.latestSummary)
        XCTAssertEqual(store.currentContent, "")
        XCTAssertEqual(store.baseSnapshot, "")
        XCTAssertNil(store.contentBaseGeneratedAt)
    }

    func testSwitchingBackRestoresConversationState() {
        let convA = UUID()
        let convB = UUID()
        let store = ScratchPadStore(defaults: defaultsSuite)

        store.activate(conversationId: convA)
        store.ingest(summary: summary("# A summary"))
        store.onPanelOpened()
        store.updateContent("# A summary\n\nmy edits")

        store.activate(conversationId: convB)
        XCTAssertEqual(store.currentContent, "")

        store.activate(conversationId: convA)
        XCTAssertEqual(store.currentContent, "# A summary\n\nmy edits")
        XCTAssertEqual(store.latestSummary?.markdown, "# A summary")
    }

    func testIngestForInactiveConversationDoesNotMutateActiveState() {
        let convA = UUID()
        let convB = UUID()
        let store = ScratchPadStore(defaults: defaultsSuite)

        store.activate(conversationId: convA)
        store.ingest(summary: summary("# A only"))
        store.onPanelOpened()

        // B generates a summary while A is still active on the panel.
        store.ingest(summary: summary("# B only"), conversationId: convB)

        // A's visible state is untouched.
        XCTAssertEqual(store.currentContent, "# A only")
        XCTAssertEqual(store.latestSummary?.markdown, "# A only")

        // B has captured its own summary — visible once we switch.
        store.activate(conversationId: convB)
        XCTAssertEqual(store.latestSummary?.markdown, "# B only")
    }

    func testActivateNilClearsObservableFieldsButPreservesCache() {
        let convA = UUID()
        let store = ScratchPadStore(defaults: defaultsSuite)

        store.activate(conversationId: convA)
        store.ingest(summary: summary("# A"))
        store.onPanelOpened()
        XCTAssertEqual(store.currentContent, "# A")

        store.activate(conversationId: nil)
        XCTAssertEqual(store.currentContent, "")
        XCTAssertNil(store.latestSummary)

        store.activate(conversationId: convA)
        XCTAssertEqual(store.currentContent, "# A")
    }

    func testPerConversationStateSurvivesStoreRestart() {
        let convA = UUID()
        let convB = UUID()

        let first = ScratchPadStore(defaults: defaultsSuite)
        first.activate(conversationId: convA)
        first.ingest(summary: summary("# A"))
        first.onPanelOpened()
        first.updateContent("# A\n\nedits in A")
        first.activate(conversationId: convB)
        first.ingest(summary: summary("# B"))
        first.onPanelOpened()

        // Simulate app restart: new store against same defaults.
        let second = ScratchPadStore(defaults: defaultsSuite)
        second.activate(conversationId: convA)
        XCTAssertEqual(second.currentContent, "# A\n\nedits in A")
        XCTAssertEqual(second.latestSummary?.markdown, "# A")

        second.activate(conversationId: convB)
        XCTAssertEqual(second.currentContent, "# B")
        XCTAssertEqual(second.latestSummary?.markdown, "# B")
    }

    func testIngestWithoutActiveConversationAndNoConversationIdIsNoOp() {
        let store = ScratchPadStore(defaults: defaultsSuite)
        // Never call activate().
        store.ingest(summary: summary("# nowhere"))
        XCTAssertNil(store.latestSummary)
    }
}
