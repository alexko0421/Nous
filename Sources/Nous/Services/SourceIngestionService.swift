import CryptoKit
import Foundation

enum SourceURLDetector {
    static func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var urls: [URL] = []

        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                continue
            }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            urls.append(url)
        }

        return urls
    }
}

struct SourceFetchedDocument: Equatable {
    let url: URL
    let title: String
    let text: String
}

enum SourceFetchError: LocalizedError, Equatable {
    case invalidResponse
    case unsupportedContent
    case emptyBody
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The source response was not usable."
        case .unsupportedContent:
            return "The source content type is not supported."
        case .emptyBody:
            return "The source did not contain readable text."
        case .tooLarge:
            return "The source was too large for V1 ingestion."
        }
    }
}

protocol SourceFetching {
    func fetch(url: URL) async throws -> SourceFetchedDocument
}

final class SourceFetchService: SourceFetching {
    private let session: URLSession
    private let maxBytes: Int

    init(session: URLSession = .shared, maxBytes: Int = 1_500_000) {
        self.session = session
        self.maxBytes = maxBytes
    }

    func fetch(url: URL) async throws -> SourceFetchedDocument {
        try await rejectOversizedContentLength(for: url)

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml,text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await cappedData(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SourceFetchError.invalidResponse
        }

        let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.isEmpty ||
              contentType.contains("text/html") ||
              contentType.contains("application/xhtml+xml") ||
              contentType.contains("text/plain") else {
            throw SourceFetchError.unsupportedContent
        }

        guard let raw = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw SourceFetchError.emptyBody
        }

        let isHTML = contentType.contains("html") || raw.range(of: "<html", options: .caseInsensitive) != nil
        let text = isHTML
            ? SourceTextExtractor.readableText(fromHTML: raw)
            : SourceTextExtractor.normalizeWhitespace(raw)
        guard !text.isEmpty else { throw SourceFetchError.emptyBody }

        let title = isHTML
            ? (SourceTextExtractor.title(fromHTML: raw) ?? Self.fallbackTitle(for: url))
            : Self.fallbackTitle(for: url)

        return SourceFetchedDocument(url: url, title: title, text: text)
    }

    private func cappedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(maxBytes) {
            throw SourceFetchError.tooLarge
        }

        var data = Data()
        data.reserveCapacity(
            response.expectedContentLength > 0
                ? min(Int(response.expectedContentLength), maxBytes)
                : min(maxBytes, 64_000)
        )

        for try await byte in bytes {
            if data.count + 1 > maxBytes {
                throw SourceFetchError.tooLarge
            }
            data.append(contentsOf: [byte])
        }
        return (data, response)
    }

    private func rejectOversizedContentLength(for url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return
            }

            let headerLength = httpResponse
                .value(forHTTPHeaderField: "Content-Length")
                .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let expectedLength = httpResponse.expectedContentLength >= 0
                ? httpResponse.expectedContentLength
                : nil
            let contentLength = headerLength ?? expectedLength
            if let contentLength, contentLength > Int64(maxBytes) {
                throw SourceFetchError.tooLarge
            }
        } catch SourceFetchError.tooLarge {
            throw SourceFetchError.tooLarge
        } catch {
            return
        }
    }

    private static func fallbackTitle(for url: URL) -> String {
        if let host = url.host, !host.isEmpty {
            return host
        }
        return url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent
    }
}

protocol SourceEmbeddingProviding {
    var isLoaded: Bool { get }
    func embed(_ text: String) throws -> [Float]
}

extension EmbeddingService: SourceEmbeddingProviding {}

final class SourceIngestionService {
    private let nodeStore: NodeStore
    private let vectorStore: VectorStore
    private let embeddingProvider: any SourceEmbeddingProviding
    private let fetcher: any SourceFetching
    private let onSourceNodeIngested: (NousNode) -> Void
    private let now: () -> Date

    init(
        nodeStore: NodeStore,
        vectorStore: VectorStore,
        embeddingProvider: any SourceEmbeddingProviding,
        fetcher: any SourceFetching = SourceFetchService(),
        onSourceNodeIngested: @escaping (NousNode) -> Void = { _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.nodeStore = nodeStore
        self.vectorStore = vectorStore
        self.embeddingProvider = embeddingProvider
        self.fetcher = fetcher
        self.onSourceNodeIngested = onSourceNodeIngested
        self.now = now
    }

    func ingestURLs(_ urls: [URL], projectId: UUID?) async throws -> [SourceMaterialContext] {
        var materials: [SourceMaterialContext] = []

        for url in urls {
            if let existing = try existingMaterial(originalURL: url.absoluteString) {
                materials.append(existing)
                continue
            }

            do {
                let fetched = try await fetcher.fetch(url: url)
                let material = try persistSource(
                    title: fetched.title,
                    text: fetched.text,
                    kind: .web,
                    originalURL: fetched.url.absoluteString,
                    originalFilename: nil,
                    projectId: projectId
                )
                materials.append(material)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }

        return materials
    }

    func ingestDocumentAttachments(
        _ attachments: [AttachedFileContext],
        projectId: UUID?
    ) throws -> [SourceMaterialContext] {
        var materials: [SourceMaterialContext] = []

        for attachment in attachments where Self.isSupportedDocumentAttachment(attachment) {
            let sourceText = attachment.sourceText ?? attachment.extractedText
            guard let sourceText,
                  !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let material = try persistSource(
                title: attachment.name,
                text: sourceText,
                kind: .document,
                originalURL: nil,
                originalFilename: attachment.name,
                projectId: projectId
            )
            materials.append(material)
        }

        return materials
    }

    func enrichedMaterials(
        _ materials: [SourceMaterialContext],
        matching query: String,
        maxChunksPerSource: Int = 3
    ) -> [SourceMaterialContext] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !materials.isEmpty,
              maxChunksPerSource > 0,
              embeddingProvider.isLoaded,
              !trimmedQuery.isEmpty,
              let queryEmbedding = try? embeddingProvider.embed(trimmedQuery) else {
            return materials
        }

        let sourceIds = Set(materials.map(\.sourceNodeId))
        let hits = (try? vectorStore.searchSourceChunks(
            query: queryEmbedding,
            topK: max(materials.count * maxChunksPerSource * 2, maxChunksPerSource),
            sourceNodeIds: sourceIds
        )) ?? []

        var chunksBySource: [UUID: [SourceChunkContext]] = [:]
        for hit in hits {
            let sourceId = hit.sourceNode.id
            guard sourceIds.contains(sourceId),
                  (chunksBySource[sourceId]?.count ?? 0) < maxChunksPerSource else {
                continue
            }
            chunksBySource[sourceId, default: []].append(
                SourceChunkContext(
                    sourceNodeId: sourceId,
                    ordinal: hit.chunk.ordinal,
                    text: hit.chunk.text,
                    similarity: hit.similarity
                )
            )
        }

        return materials.map { material in
            guard let rankedChunks = chunksBySource[material.sourceNodeId],
                  !rankedChunks.isEmpty else {
                return material
            }
            return SourceMaterialContext(
                sourceNodeId: material.sourceNodeId,
                title: material.title,
                originalURL: material.originalURL,
                originalFilename: material.originalFilename,
                chunks: rankedChunks
            )
        }
    }

    static func isSupportedDocumentAttachment(_ attachment: AttachedFileContext) -> Bool {
        guard !AttachmentLimitPolicy.isImageAttachment(attachment) else { return false }
        let ext = URL(fileURLWithPath: attachment.name).pathExtension.lowercased()
        return ["pdf", "txt", "md", "markdown", "csv", "json"].contains(ext)
    }

    private func existingMaterial(originalURL: String) throws -> SourceMaterialContext? {
        guard let metadata = try nodeStore.fetchSourceMetadata(originalURL: originalURL) else { return nil }
        return try materialContext(nodeId: metadata.nodeId)
    }

    private func persistSource(
        title: String,
        text: String,
        kind: SourceKind,
        originalURL: String?,
        originalFilename: String?,
        projectId: UUID?
    ) throws -> SourceMaterialContext {
        let normalizedText = SourceTextExtractor.normalizeWhitespace(text)
        let hash = Self.contentHash(normalizedText)
        if let existing = try nodeStore.fetchSourceMetadata(contentHash: hash),
           let material = try materialContext(nodeId: existing.nodeId) {
            return material
        }

        let createdAt = now()
        let embedding = embeddingProvider.isLoaded
            ? try? embeddingProvider.embed(Self.embeddingInput(normalizedText))
            : nil
        let node = NousNode(
            type: .source,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Source" : title,
            content: normalizedText,
            emoji: kind == .web ? "🔗" : "📄",
            embedding: embedding,
            projectId: projectId,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let chunks = Self.chunks(
            from: normalizedText,
            sourceNodeId: node.id,
            embeddingProvider: embeddingProvider,
            createdAt: createdAt
        )

        try nodeStore.insertSource(
            node: node,
            metadata: SourceMetadata(
                nodeId: node.id,
                kind: kind,
                originalURL: originalURL,
                originalFilename: originalFilename,
                contentHash: hash,
                ingestedAt: createdAt,
                extractionStatus: .ready
            ),
            chunks: chunks
        )
        onSourceNodeIngested(node)
        return try materialContext(nodeId: node.id) ?? SourceMaterialContext(
            sourceNodeId: node.id,
            title: node.title,
            originalURL: originalURL,
            originalFilename: originalFilename,
            chunks: []
        )
    }

    private func materialContext(nodeId: UUID) throws -> SourceMaterialContext? {
        guard let node = try nodeStore.fetchNode(id: nodeId),
              let metadata = try nodeStore.fetchSourceMetadata(nodeId: nodeId) else {
            return nil
        }
        let chunks = try nodeStore.fetchSourceChunks(nodeId: nodeId)
            .prefix(3)
            .map {
                SourceChunkContext(
                    sourceNodeId: $0.sourceNodeId,
                    ordinal: $0.ordinal,
                    text: $0.text,
                    similarity: nil
                )
            }
        return SourceMaterialContext(
            sourceNodeId: node.id,
            title: node.title,
            originalURL: metadata.originalURL,
            originalFilename: metadata.originalFilename,
            chunks: Array(chunks)
        )
    }

    private static func chunks(
        from text: String,
        sourceNodeId: UUID,
        embeddingProvider: any SourceEmbeddingProviding,
        createdAt: Date
    ) -> [SourceChunk] {
        let maxCharacters = 1_200
        let overlap = 160
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }

        var chunks: [SourceChunk] = []
        var start = 0
        var ordinal = 0

        while start < characters.count {
            let end = min(start + maxCharacters, characters.count)
            let chunkText = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunkText.isEmpty {
                let embedding = embeddingProvider.isLoaded ? try? embeddingProvider.embed(chunkText) : nil
                chunks.append(
                    SourceChunk(
                        sourceNodeId: sourceNodeId,
                        ordinal: ordinal,
                        text: chunkText,
                        embedding: embedding,
                        createdAt: createdAt
                    )
                )
                ordinal += 1
            }
            if end == characters.count { break }
            start = max(end - overlap, start + 1)
        }

        return chunks
    }

    private static func embeddingInput(_ text: String) -> String {
        String(text.prefix(4_000))
    }

    private static func contentHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
