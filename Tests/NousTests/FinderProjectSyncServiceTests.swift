import XCTest
@testable import Nous

final class FinderProjectSyncServiceTests: XCTestCase {

    private var store: NodeStore!
    private var tempDirectoryURL: URL!
    private var exportRootURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        exportRootURL = tempDirectoryURL.appendingPathComponent("Finder Export", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)

        let dbURL = tempDirectoryURL.appendingPathComponent("nous.sqlite", isDirectory: false)
        store = try NodeStore(path: dbURL.path)
    }

    override func tearDownWithError() throws {
        store = nil
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        exportRootURL = nil
        try super.tearDownWithError()
    }

    func testSyncExportsWholeProjectIntoFinderFolders() throws {
        let project = Project(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "New York Launch",
            goal: "Ship the whole project into Finder.",
            emoji: "NY"
        )
        try store.insertProject(project)

        let note = NousNode(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            type: .note,
            title: "Launch checklist",
            content: "- wire Finder sync\n- verify export",
            projectId: project.id
        )
        try store.insertNode(note)

        let conversation = NousNode(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            type: .conversation,
            title: "Importer chat",
            content: "",
            projectId: project.id
        )
        try store.insertNode(conversation)
        try store.insertMessage(Message(nodeId: conversation.id, role: .user, content: "Put everything into Finder."))
        try store.insertMessage(Message(nodeId: conversation.id, role: .assistant, content: "Exporting the full project now."))

        let service = FinderProjectSyncService(
            nodeStore: store,
            rootURLProvider: { self.exportRootURL }
        )
        service.syncNow()

        let projectFolder = exportRootURL.appendingPathComponent("New York Launch [11111111]", isDirectory: true)
        let summary = try String(contentsOf: projectFolder.appendingPathComponent("Project.md"))
        XCTAssertTrue(summary.contains("Ship the whole project into Finder."))

        let noteExport = try String(
            contentsOf: projectFolder
                .appendingPathComponent("Notes", isDirectory: true)
                .appendingPathComponent("Launch checklist [22222222].md")
        )
        XCTAssertTrue(noteExport.contains("- wire Finder sync"))

        let conversationExport = try String(
            contentsOf: projectFolder
                .appendingPathComponent("Conversations", isDirectory: true)
                .appendingPathComponent("Importer chat [33333333].md")
        )
        XCTAssertTrue(conversationExport.contains("## User"))
        XCTAssertTrue(conversationExport.contains("Put everything into Finder."))
        XCTAssertTrue(conversationExport.contains("## Nous"))
        XCTAssertTrue(conversationExport.contains("Exporting the full project now."))
    }

    func testSyncClearsManagedRootAndExportsInboxNodes() throws {
        let staleFileURL = exportRootURL.appendingPathComponent("stale.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: exportRootURL, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: staleFileURL)

        let inboxNote = NousNode(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            type: .note,
            title: "Loose note",
            content: "Still needs a project."
        )
        try store.insertNode(inboxNote)

        let service = FinderProjectSyncService(
            nodeStore: store,
            rootURLProvider: { self.exportRootURL }
        )
        service.syncNow()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFileURL.path))

        let inboxFolder = exportRootURL.appendingPathComponent("Inbox [inbox]", isDirectory: true)
        let inboxNoteExport = try String(
            contentsOf: inboxFolder
                .appendingPathComponent("Notes", isDirectory: true)
                .appendingPathComponent("Loose note [44444444].md")
        )
        XCTAssertTrue(inboxNoteExport.contains("Still needs a project."))
    }

    func testSyncOmitsAssistantThinkingWhenPreferenceIsOff() throws {
        let conversation = NousNode(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            type: .conversation,
            title: "Privacy chat",
            content: ""
        )
        try store.insertNode(conversation)
        try store.insertMessage(Message(nodeId: conversation.id, role: .user, content: "Think through this."))
        try store.insertMessage(
            Message(
                nodeId: conversation.id,
                role: .assistant,
                content: "Here is the answer.",
                thinkingContent: "Hidden reasoning"
            )
        )

        let service = FinderProjectSyncService(
            nodeStore: store,
            rootURLProvider: { self.exportRootURL },
            shouldExportAssistantThinking: { false }
        )
        service.syncNow()

        let conversationExport = try String(
            contentsOf: exportRootURL
                .appendingPathComponent("Inbox [inbox]", isDirectory: true)
                .appendingPathComponent("Conversations", isDirectory: true)
                .appendingPathComponent("Privacy chat [55555555].md")
        )

        XCTAssertTrue(conversationExport.contains("Here is the answer."))
        XCTAssertFalse(conversationExport.contains("### Thinking"))
        XCTAssertFalse(conversationExport.contains("Hidden reasoning"))
    }
}
