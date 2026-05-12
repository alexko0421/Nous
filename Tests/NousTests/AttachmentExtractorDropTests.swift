import UniformTypeIdentifiers
import XCTest
@testable import Nous

final class AttachmentExtractorDropTests: XCTestCase {
    func testDroppedAttachmentContextsReadsFileRepresentationWhenFileURLIsUnavailable() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nous-drop-file-representation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("notes.txt")
        try Data("dragged file body".utf8).write(to: url)

        let provider = NSItemProvider()
        provider.suggestedName = "notes.txt"
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.plainText.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(url, true, nil)
            return nil
        }

        let contexts = await AttachmentExtractor.droppedAttachmentContexts(from: [provider])

        XCTAssertEqual(contexts.map(\.name), ["notes.txt"])
        XCTAssertEqual(contexts.first?.sourceText, "dragged file body")
    }
}
