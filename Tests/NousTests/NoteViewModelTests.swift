import XCTest
@testable import Nous

final class NoteViewModelTests: XCTestCase {
    private var store: NodeStore!
    private var vm: NoteViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: store)
        vm = NoteViewModel(
            nodeStore: store,
            vectorStore: vectorStore,
            embeddingService: EmbeddingService(),
            graphEngine: GraphEngine(nodeStore: store, vectorStore: vectorStore)
        )
    }

    override func tearDownWithError() throws {
        vm = nil
        store = nil
        try super.tearDownWithError()
    }

    func testCreateNoteWithTitleAndContentPersistsAndOpensNote() throws {
        try vm.createNote(title: "Voice Note", content: "Captured by voice.", projectId: nil)

        XCTAssertEqual(vm.currentNote?.title, "Voice Note")
        XCTAssertEqual(vm.title, "Voice Note")
        XCTAssertEqual(vm.content, "Captured by voice.")

        let notes = try store.fetchAllNodes().filter { $0.type == .note }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.title, "Voice Note")
        XCTAssertEqual(notes.first?.content, "Captured by voice.")
    }

    func testCreateNoteWithBlankTitleFallsBackToUntitled() throws {
        try vm.createNote(title: "   ", content: "Body", projectId: nil)

        XCTAssertEqual(vm.currentNote?.title, "Untitled")
        XCTAssertEqual(vm.content, "Body")
    }
}
