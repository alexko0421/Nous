import XCTest
@testable import Nous

final class SourceURLDetectorTests: XCTestCase {
    func testDetectsDedupedHTTPURLsAndTrimsTrailingPunctuation() {
        let urls = SourceURLDetector.urls(
            in: "Read https://example.com/report?x=1, then compare with (https://example.com/report?x=1). Also https://nous.local/path."
        )

        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://example.com/report?x=1",
            "https://nous.local/path"
        ])
    }
}

final class SourceTextExtractorTests: XCTestCase {
    func testReadableHTMLExtractionRemovesScriptsStylesAndTags() {
        let html = """
        <html>
          <head><style>.hidden { display: none; }</style><script>var secret = 1;</script></head>
          <body><h1>Fund memo</h1><p>Connect external research to memory.</p></body>
        </html>
        """

        let text = SourceTextExtractor.readableText(fromHTML: html)

        XCTAssertTrue(text.contains("Fund memo"))
        XCTAssertTrue(text.contains("Connect external research to memory."))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("display: none"))
        XCTAssertFalse(text.contains("<p>"))
    }
}

final class SourceStoreTests: XCTestCase {
    func testSourceNodeMetadataAndChunksRoundTrip() throws {
        let store = try NodeStore(path: ":memory:")
        let now = Date(timeIntervalSince1970: 1_234)
        let node = NousNode(
            type: .source,
            title: "External memo",
            content: "Source body",
            emoji: "🔗",
            createdAt: now,
            updatedAt: now
        )

        try store.insertNode(node)
        try store.upsertSourceMetadata(
            SourceMetadata(
                nodeId: node.id,
                kind: .web,
                originalURL: "https://example.com/memo",
                originalFilename: nil,
                contentHash: "hash-1",
                ingestedAt: now,
                extractionStatus: .ready
            )
        )
        try store.replaceSourceChunks([
            SourceChunk(
                sourceNodeId: node.id,
                ordinal: 0,
                text: "First source chunk",
                embedding: [1, 0],
                createdAt: now
            ),
            SourceChunk(
                sourceNodeId: node.id,
                ordinal: 1,
                text: "Second source chunk",
                embedding: [0, 1],
                createdAt: now
            )
        ], for: node.id)

        let fetched = try XCTUnwrap(store.fetchNode(id: node.id))
        XCTAssertEqual(fetched.type, .source)
        XCTAssertEqual(try store.fetchSourceMetadata(nodeId: node.id)?.originalURL, "https://example.com/memo")
        XCTAssertEqual(try store.fetchSourceMetadata(contentHash: "hash-1")?.nodeId, node.id)
        XCTAssertEqual(try store.fetchSourceChunks(nodeId: node.id).map(\.text), [
            "First source chunk",
            "Second source chunk"
        ])
    }
}

final class SourceChunkVectorSearchTests: XCTestCase {
    func testSearchSourceChunksReturnsMostRelevantChunk() throws {
        let store = try NodeStore(path: ":memory:")
        let vectorStore = VectorStore(nodeStore: store)
        let node = NousNode(type: .source, title: "Research PDF", content: "full text", embedding: [1, 0])
        try store.insertNode(node)
        try store.replaceSourceChunks([
            SourceChunk(sourceNodeId: node.id, ordinal: 0, text: "visa school logistics", embedding: [0, 1]),
            SourceChunk(sourceNodeId: node.id, ordinal: 1, text: "source analysis connects ideas", embedding: [1, 0])
        ], for: node.id)

        let results = try vectorStore.searchSourceChunks(query: [1, 0], topK: 1)

        XCTAssertEqual(results.first?.sourceNode.id, node.id)
        XCTAssertEqual(results.first?.chunk.text, "source analysis connects ideas")
    }
}

final class SourceIngestionServiceTests: XCTestCase {
    func testIngestURLCreatesDedupedSourceNodeAndChunks() async throws {
        let store = try NodeStore(path: ":memory:")
        let service = SourceIngestionService(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingProvider: StubSourceEmbeddingProvider(),
            fetcher: StubSourceFetcher(
                result: .success(
                    SourceFetchedDocument(
                        url: URL(string: "https://example.com/article")!,
                        title: "Article title",
                        text: "Source analysis should connect external research to Alex's memory graph."
                    )
                )
            )
        )

        let first = try await service.ingestURLs([URL(string: "https://example.com/article")!], projectId: nil)
        let second = try await service.ingestURLs([URL(string: "https://example.com/article")!], projectId: nil)

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(first[0].sourceNodeId, second[0].sourceNodeId)
        XCTAssertEqual(try store.fetchAllNodes().filter { $0.type == .source }.count, 1)
        XCTAssertFalse(try store.fetchSourceChunks(nodeId: first[0].sourceNodeId).isEmpty)
    }

    func testURLIngestionRollsBackSourceNodeWhenChunkWriteFails() async throws {
        let store = try NodeStore(path: ":memory:")
        try store.rawDatabase.exec("""
            CREATE TRIGGER fail_source_chunk_insert
            BEFORE INSERT ON source_chunks
            BEGIN
                SELECT RAISE(FAIL, 'chunk write failed');
            END;
        """)
        let service = SourceIngestionService(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingProvider: StubSourceEmbeddingProvider(),
            fetcher: StubSourceFetcher(
                result: .success(
                    SourceFetchedDocument(
                        url: URL(string: "https://example.com/article")!,
                        title: "Article title",
                        text: "Source analysis should connect external research to Alex's graph."
                    )
                )
            )
        )

        let materials = try await service.ingestURLs([URL(string: "https://example.com/article")!], projectId: nil)

        XCTAssertTrue(materials.isEmpty)
        XCTAssertTrue(try store.fetchAllNodes().filter { $0.type == .source }.isEmpty)
        XCTAssertEqual(try countRows(in: store, table: "source_metadata"), 0)
        XCTAssertEqual(try countRows(in: store, table: "source_chunks"), 0)
    }

    func testIngestDocumentAttachmentCreatesSourceNodeNotNote() throws {
        let store = try NodeStore(path: ":memory:")
        let service = SourceIngestionService(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingProvider: StubSourceEmbeddingProvider()
        )

        let materials = try service.ingestDocumentAttachments(
            [AttachedFileContext(name: "research.pdf", extractedText: "Document source body that should connect ideas.")],
            projectId: nil
        )

        XCTAssertEqual(materials.count, 1)
        let nodes = try store.fetchAllNodes()
        XCTAssertEqual(nodes.filter { $0.type == .source }.count, 1)
        XCTAssertEqual(nodes.filter { $0.type == .note }.count, 0)
        XCTAssertEqual(try store.fetchSourceMetadata(nodeId: materials[0].sourceNodeId)?.kind, .document)
    }

    func testDocumentAttachmentIngestionUsesFullSourceTextNotChatPreview() throws {
        let store = try NodeStore(path: ":memory:")
        let service = SourceIngestionService(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingProvider: StubSourceEmbeddingProvider()
        )
        let fullText = String(repeating: "front matter ", count: 360) + "tail section only appears after preview cap"
        let preview = String(fullText.prefix(4_000))

        let materials = try service.ingestDocumentAttachments(
            [
                AttachedFileContext(
                    name: "long-report.txt",
                    extractedText: preview,
                    sourceText: fullText
                )
            ],
            projectId: nil
        )

        let node = try XCTUnwrap(try store.fetchNode(id: materials[0].sourceNodeId))
        XCTAssertTrue(node.content.contains("tail section only appears after preview cap"))
        XCTAssertTrue(try store.fetchSourceChunks(nodeId: node.id).contains {
            $0.text.contains("tail section only appears after preview cap")
        })
    }

    func testSourceIngestionCallbackReceivesEmbeddedSourceNodeForGalaxyRegeneration() async throws {
        let store = try NodeStore(path: ":memory:")
        var ingestedNodes: [NousNode] = []
        let service = SourceIngestionService(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingProvider: StubSourceEmbeddingProvider(),
            fetcher: StubSourceFetcher(
                result: .success(
                    SourceFetchedDocument(
                        url: URL(string: "https://example.com/article")!,
                        title: "Article title",
                        text: "Source analysis should connect external research to Alex's graph."
                    )
                )
            ),
            onSourceNodeIngested: { ingestedNodes.append($0) }
        )

        _ = try await service.ingestURLs([URL(string: "https://example.com/article")!], projectId: nil)

        XCTAssertEqual(ingestedNodes.count, 1)
        XCTAssertNotNil(ingestedNodes.first?.embedding)
    }

    func testSourceIngestionDoesNotWritePersonalMemoryTables() async throws {
        let store = try NodeStore(path: ":memory:")
        let service = SourceIngestionService(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingProvider: StubSourceEmbeddingProvider(),
            fetcher: StubSourceFetcher(
                result: .success(
                    SourceFetchedDocument(
                        url: URL(string: "https://example.com/article")!,
                        title: "Article title",
                        text: "External source material is evidence, not Alex identity memory."
                    )
                )
            )
        )

        _ = try await service.ingestURLs([URL(string: "https://example.com/article")!], projectId: nil)

        XCTAssertTrue(try store.fetchMemoryEntries().isEmpty)
        XCTAssertTrue(try store.fetchMemoryFactEntries().isEmpty)
        XCTAssertTrue(try store.fetchMemoryAtoms().isEmpty)
    }

    func testFailedFetchDoesNotCreateSourceNode() async throws {
        let store = try NodeStore(path: ":memory:")
        let service = SourceIngestionService(
            nodeStore: store,
            vectorStore: VectorStore(nodeStore: store),
            embeddingProvider: StubSourceEmbeddingProvider(),
            fetcher: StubSourceFetcher(result: .failure(SourceFetchError.unsupportedContent))
        )

        let materials = try await service.ingestURLs([URL(string: "https://example.com/private")!], projectId: nil)

        XCTAssertTrue(materials.isEmpty)
        XCTAssertTrue(try store.fetchAllNodes().filter { $0.type == .source }.isEmpty)
    }
}

final class SourceFetchServiceTests: XCTestCase {
    override func tearDown() {
        SourceFetchMockURLProtocol.handler = nil
        SourceFetchMockURLProtocol.streamingHandler = nil
        SourceFetchMockURLProtocol.requests = []
        SourceFetchMockURLProtocol.chunksSent = 0
        super.tearDown()
    }

    func testRejectsOversizedContentLengthBeforeGETBodyDownload() async throws {
        SourceFetchMockURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Length": "1000",
                            "Content-Type": "text/html"
                        ]
                    )!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!,
                Data("<html><body>should not download</body></html>".utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceFetchMockURLProtocol.self]
        let service = SourceFetchService(
            session: URLSession(configuration: configuration),
            maxBytes: 100
        )

        do {
            _ = try await service.fetch(url: URL(string: "https://example.com/large")!)
            XCTFail("Expected oversized source to be rejected before GET.")
        } catch SourceFetchError.tooLarge {
            XCTAssertEqual(SourceFetchMockURLProtocol.requests.map(\.httpMethod), ["HEAD"])
        } catch {
            XCTFail("Expected tooLarge, got \(error).")
        }
    }

    func testStopsStreamingGETWhenBodyExceedsMaxBytesWithoutContentLength() async throws {
        let expectedChunks = 8
        SourceFetchMockURLProtocol.streamingHandler = { request, loader in
            if request.httpMethod == "HEAD" {
                loader.send(
                    response: HTTPURLResponse(
                        url: request.url!,
                        statusCode: 405,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "text/html"]
                    )!
                )
                loader.finish()
                return
            }

            loader.send(
                response: HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!
            )
            Task {
                for index in 0..<expectedChunks {
                    if loader.isStopped { break }
                    let chunk = "<p>\(index) \(String(repeating: "source body ", count: 20))</p>"
                    loader.send(data: Data(chunk.utf8))
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                loader.finish()
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceFetchMockURLProtocol.self]
        let service = SourceFetchService(
            session: URLSession(configuration: configuration),
            maxBytes: 120
        )

        do {
            _ = try await service.fetch(url: URL(string: "https://example.com/chunked-large")!)
            XCTFail("Expected chunked source to be capped.")
        } catch SourceFetchError.tooLarge {
            try await Task.sleep(nanoseconds: 80_000_000)
            XCTAssertLessThan(SourceFetchMockURLProtocol.chunksSent, expectedChunks)
        } catch {
            XCTFail("Expected tooLarge, got \(error).")
        }
    }
}

private func countRows(in store: NodeStore, table: String) throws -> Int {
    let stmt = try store.rawDatabase.prepare("SELECT COUNT(*) FROM \(table);")
    guard try stmt.step() else { return 0 }
    return stmt.int(at: 0)
}

private struct StubSourceEmbeddingProvider: SourceEmbeddingProviding {
    var isLoaded: Bool { true }

    func embed(_ text: String) throws -> [Float] {
        text.lowercased().contains("connect") ? [1, 0] : [0, 1]
    }
}

private struct StubSourceFetcher: SourceFetching {
    let result: Result<SourceFetchedDocument, Error>

    func fetch(url: URL) async throws -> SourceFetchedDocument {
        try result.get()
    }
}

private final class SourceFetchMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    static var streamingHandler: ((URLRequest, SourceFetchMockURLProtocol) -> Void)?
    static var requests: [URLRequest] = []
    static var chunksSent = 0
    private let stopLock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(request)
        if let streamingHandler = Self.streamingHandler {
            streamingHandler(request, self)
            return
        }

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: SourceFetchError.invalidResponse)
            return
        }

        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
    }

    func send(response: HTTPURLResponse) {
        guard !isStopped else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func send(data: Data) {
        guard !isStopped else { return }
        Self.chunksSent += 1
        client?.urlProtocol(self, didLoad: data)
    }

    func finish() {
        guard !isStopped else { return }
        client?.urlProtocolDidFinishLoading(self)
    }
}
