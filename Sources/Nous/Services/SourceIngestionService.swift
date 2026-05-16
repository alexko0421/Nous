import CryptoKit
import Darwin
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
                  SourceURLSafety.allowsNetworkFetch(url) else {
                continue
            }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            urls.append(url)
        }

        return urls
    }
}

enum SourceURLSafety {
    static func allowsNetworkFetch(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = url.host else {
            return false
        }

        let host = normalizedHost(rawHost)
        guard !host.isEmpty,
              !containsUnsafeHostScalar(host),
              !isBlockedName(host) else {
            return false
        }

        if let octets = ipv4Octets(host) {
            return isPublicIPv4(octets)
        }
        if isDottedIPAddressAlias(host) {
            return false
        }

        if host.contains(":") {
            return isPublicIPv6Literal(host)
        }

        // Single-label hosts are local/intranet names, not public source material.
        return host.contains(".")
    }

    static func allowsResolvedIPAddress(_ host: String) -> Bool {
        let normalized = normalizedHost(host)
        if let octets = ipv4Octets(normalized) {
            return isPublicIPv4(octets)
        }
        if normalized.contains(":") {
            return isPublicIPv6Literal(normalized)
        }
        return false
    }

    private static func normalizedHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private static func isBlockedName(_ host: String) -> Bool {
        host == "localhost" ||
            host.hasSuffix(".localhost") ||
            host.hasSuffix(".local")
    }

    private static func containsUnsafeHostScalar(_ host: String) -> Bool {
        let blockedDelimiters = CharacterSet(charactersIn: "\\/@?#")
        return host.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) ||
                CharacterSet.whitespacesAndNewlines.contains(scalar) ||
                CharacterSet.illegalCharacters.contains(scalar) ||
                blockedDelimiters.contains(scalar)
        }
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }

        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  !(part.count > 1 && part.first == "0"),
                  part.allSatisfy(\.isNumber),
                  let value = Int(part),
                  (0...255).contains(value) else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }

    private static func isDottedIPAddressAlias(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return false }
        guard (2...4).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            isDecimalIPAddressComponent(part) || isHexIPAddressComponent(part)
        }
    }

    private static func isDecimalIPAddressComponent(_ part: Substring) -> Bool {
        !part.isEmpty && part.allSatisfy(\.isNumber)
    }

    private static func isHexIPAddressComponent(_ part: Substring) -> Bool {
        let value = String(part)
        guard value.hasPrefix("0x") else { return false }

        let hexDigits = value.dropFirst(2)
        guard !hexDigits.isEmpty else { return false }

        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        return hexDigits.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isPublicIPv4(_ octets: [Int]) -> Bool {
        guard octets.count == 4 else { return false }
        let a = octets[0]
        let b = octets[1]
        let c = octets[2]

        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 100 && (64...127).contains(b) { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        if a == 192 && b == 0 { return false }
        if a == 192 && b == 88 && c == 99 { return false }
        if a == 198 && (b == 18 || b == 19) { return false }
        if a == 198 && b == 51 && c == 100 { return false }
        if a == 203 && b == 0 && c == 113 { return false }
        return true
    }

    private static func isPublicIPv6Literal(_ host: String) -> Bool {
        guard let bytes = ipv6LiteralBytes(host) else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0] == 0xfe { return false }
        if (bytes[0] & 0xfe) == 0xfc { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 {
            return false
        }
        if isNonGlobalSpecialIPv6(bytes) {
            return false
        }
        if isTeredoIPv6(bytes) || isLocalUseNAT64IPv6(bytes) {
            return false
        }
        if let embeddedIPv4 = wellKnownNAT64IPv4(bytes) {
            return isPublicIPv4(embeddedIPv4.map(Int.init))
        }
        if let embeddedIPv4 = sixToFourIPv4(bytes) {
            return isPublicIPv4(embeddedIPv4.map(Int.init))
        }
        if isIPv4MappedIPv6(bytes) {
            return isPublicIPv4(bytes[12...15].map(Int.init))
        }
        if isIPv4CompatibleIPv6(bytes) {
            return false
        }
        return true
    }

    private static func ipv6LiteralBytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func isIPv4MappedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        return bytes[0..<10].allSatisfy { $0 == 0 } &&
            bytes[10] == 0xff &&
            bytes[11] == 0xff
    }

    private static func isIPv4CompatibleIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        return bytes[0..<12].allSatisfy { $0 == 0 }
    }

    private static func isTeredoIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        return bytes[0] == 0x20 &&
            bytes[1] == 0x01 &&
            bytes[2] == 0x00 &&
            bytes[3] == 0x00
    }

    private static func isLocalUseNAT64IPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        return bytes[0] == 0x00 &&
            bytes[1] == 0x64 &&
            bytes[2] == 0xff &&
            bytes[3] == 0x9b &&
            bytes[4] == 0x00 &&
            bytes[5] == 0x01
    }

    private static func isNonGlobalSpecialIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0] == 0x01 && bytes[1] == 0x00 && bytes[2..<8].allSatisfy({ $0 == 0 }) {
            return true // 100::/64 discard-only.
        }
        if bytes[0] == 0x01 &&
            bytes[1] == 0x00 &&
            bytes[2] == 0x00 &&
            bytes[3] == 0x00 &&
            bytes[4] == 0x00 &&
            bytes[5] == 0x00 &&
            bytes[6] == 0x00 &&
            bytes[7] == 0x01 {
            return true // 100:0:0:1::/64 dummy IPv6 prefix.
        }
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            if bytes[2] == 0x00 && bytes[3] == 0x02 && bytes[4] == 0x00 && bytes[5] == 0x00 {
                return true // 2001:2::/48 benchmarking.
            }
            if bytes[2] == 0x00 && (bytes[3] & 0xf0) == 0x10 {
                return true // 2001:10::/28 deprecated ORCHID.
            }
        }
        if bytes[0] == 0x3f && bytes[1] == 0xff && (bytes[2] & 0xf0) == 0x00 {
            return true // 3fff::/20 documentation.
        }
        if bytes[0] == 0x5f && bytes[1] == 0x00 {
            return true // 5f00::/16 SRv6 SIDs, not globally reachable.
        }
        return false
    }

    private static func wellKnownNAT64IPv4(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count == 16 else { return nil }
        let prefix: [UInt8] = [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]
        guard Array(bytes[0..<12]) == prefix else { return nil }
        return Array(bytes[12...15])
    }

    private static func sixToFourIPv4(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count == 16,
              bytes[0] == 0x20,
              bytes[1] == 0x02 else {
            return nil
        }
        return Array(bytes[2...5])
    }
}

enum SourceDNSResolver {
    static func resolvedAddressesArePublic(_ addresses: [String]) -> Bool {
        !addresses.isEmpty && addresses.allSatisfy(SourceURLSafety.allowsResolvedIPAddress(_:))
    }

    static func resolvesOnlyToPublicAddresses(_ url: URL) -> Bool {
        guard let rawHost = url.host else { return false }
        let host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return false }

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var resultInfo: UnsafeMutablePointer<addrinfo>?
        let result = getaddrinfo(host, nil, &hints, &resultInfo)
        guard result == 0, let resultInfo else { return false }
        defer { freeaddrinfo(resultInfo) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = resultInfo
        while let current = cursor {
            if let address = numericHost(from: current.pointee) {
                addresses.append(address)
            }
            cursor = current.pointee.ai_next
        }
        return resolvedAddressesArePublic(addresses)
    }

    private static func numericHost(from info: addrinfo) -> String? {
        guard let address = info.ai_addr else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            info.ai_addrlen,
            &buffer,
            socklen_t(buffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        return String(cString: buffer)
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
    case disallowedURL

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
        case .disallowedURL:
            return "The source URL points to a local or private network address."
        }
    }
}

protocol SourceFetching {
    func fetch(url: URL) async throws -> SourceFetchedDocument
}

final class SourceFetchService: SourceFetching {
    private let session: URLSession
    private let redirectGuard: SourceFetchRedirectGuard?
    private let maxBytes: Int
    private let resolveNetworkAddresses: Bool
    private let dnsResolution: @Sendable (URL) -> Bool

    init(
        session: URLSession? = nil,
        maxBytes: Int = 1_500_000,
        dnsResolution: @escaping @Sendable (URL) -> Bool = {
            SourceDNSResolver.resolvesOnlyToPublicAddresses($0)
        }
    ) {
        if let session {
            self.session = session
            self.redirectGuard = nil
            self.resolveNetworkAddresses = false
        } else {
            let redirectGuard = SourceFetchRedirectGuard(dnsResolution: dnsResolution)
            self.redirectGuard = redirectGuard
            self.session = URLSession(
                configuration: .ephemeral,
                delegate: redirectGuard,
                delegateQueue: nil
            )
            self.resolveNetworkAddresses = true
        }
        self.maxBytes = maxBytes
        self.dnsResolution = dnsResolution
    }

    init(
        configuration: URLSessionConfiguration,
        maxBytes: Int = 1_500_000,
        resolveNetworkAddresses: Bool = false,
        dnsResolution: @escaping @Sendable (URL) -> Bool = {
            SourceDNSResolver.resolvesOnlyToPublicAddresses($0)
        }
    ) {
        let redirectGuard = SourceFetchRedirectGuard(
            resolveNetworkAddresses: resolveNetworkAddresses,
            dnsResolution: dnsResolution
        )
        self.redirectGuard = redirectGuard
        self.session = URLSession(
            configuration: configuration,
            delegate: redirectGuard,
            delegateQueue: nil
        )
        self.maxBytes = maxBytes
        self.resolveNetworkAddresses = resolveNetworkAddresses
        self.dnsResolution = dnsResolution
    }

    func fetch(url: URL) async throws -> SourceFetchedDocument {
        guard SourceURLSafety.allowsNetworkFetch(url) else {
            throw SourceFetchError.disallowedURL
        }
        if resolveNetworkAddresses {
            let addressesArePublic = await resolvedNetworkAddressesArePublic(url)
            if !addressesArePublic {
                throw SourceFetchError.disallowedURL
            }
        }
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

    private func resolvedNetworkAddressesArePublic(_ url: URL) async -> Bool {
        let dnsResolution = dnsResolution
        return await Task.detached(priority: .utility) {
            dnsResolution(url)
        }.value
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

final class SourceFetchRedirectGuard: NSObject, URLSessionTaskDelegate {
    private let resolveNetworkAddresses: Bool
    private let dnsResolution: @Sendable (URL) -> Bool

    init(
        resolveNetworkAddresses: Bool = true,
        dnsResolution: @escaping @Sendable (URL) -> Bool = {
            SourceDNSResolver.resolvesOnlyToPublicAddresses($0)
        }
    ) {
        self.resolveNetworkAddresses = resolveNetworkAddresses
        self.dnsResolution = dnsResolution
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              SourceURLSafety.allowsNetworkFetch(url),
              !resolveNetworkAddresses || dnsResolution(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
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
            guard SourceURLSafety.allowsNetworkFetch(url) else { continue }
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
                    evidenceLevel: .unknown,
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
                evidenceLevel: .unknown,
                projectId: projectId
            )
            materials.append(material)
        }

        return materials
    }

    func ingestExtractedSource(
        title: String,
        text: String,
        kind: SourceKind,
        originalURL: String?,
        originalFilename: String?,
        evidenceLevel: SourceEvidenceLevel = .unknown,
        projectId: UUID?
    ) throws -> SourceMaterialContext {
        try persistSource(
            title: title,
            text: text,
            kind: kind,
            originalURL: originalURL,
            originalFilename: originalFilename,
            evidenceLevel: evidenceLevel,
            projectId: projectId
        )
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

        let enrichableMaterials = materials.filter { !Self.preservesSelectedDiscussionPayload($0) }
        guard !enrichableMaterials.isEmpty else {
            return materials
        }

        let sourceIds = Set(enrichableMaterials.map(\.sourceNodeId))
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
            guard !Self.preservesSelectedDiscussionPayload(material) else {
                return material
            }
            guard let rankedChunks = chunksBySource[material.sourceNodeId],
                  !rankedChunks.isEmpty else {
                return material
            }
            return SourceMaterialContext(
                sourceNodeId: material.sourceNodeId,
                title: material.title,
                originalURL: material.originalURL,
                originalFilename: material.originalFilename,
                chunks: rankedChunks,
                summaryMap: material.summaryMap,
                evidenceLevel: material.evidenceLevel
            )
        }
    }

    private static func preservesSelectedDiscussionPayload(_ material: SourceMaterialContext) -> Bool {
        material.chunks.contains { chunk in
            let normalized = chunk.text.lowercased()
            return normalized.contains("youtube section:") &&
                normalized.contains("evidence:")
        }
    }

    static func isSupportedDocumentAttachment(_ attachment: AttachedFileContext) -> Bool {
        guard !AttachmentLimitPolicy.isImageAttachment(attachment) else { return false }
        let ext = URL(fileURLWithPath: attachment.name).pathExtension.lowercased()
        return ["pdf", "txt", "md", "markdown", "csv", "json"].contains(ext)
    }

    private static func emoji(for kind: SourceKind) -> String {
        switch kind {
        case .web:
            return "🔗"
        case .document:
            return "📄"
        case .youtube:
            return "▶"
        }
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
        evidenceLevel: SourceEvidenceLevel,
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
            emoji: Self.emoji(for: kind),
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
                extractionStatus: .ready,
                evidenceLevel: evidenceLevel
            ),
            chunks: chunks
        )
        onSourceNodeIngested(node)
        return try materialContext(nodeId: node.id) ?? SourceMaterialContext(
            sourceNodeId: node.id,
            title: node.title,
            originalURL: originalURL,
            originalFilename: originalFilename,
            chunks: [],
            summaryMap: SourceSummaryMapBuilder.build(
                kind: kind,
                originalFilename: originalFilename,
                text: normalizedText,
                chunks: chunks
            ),
            evidenceLevel: evidenceLevel
        )
    }

    private func materialContext(nodeId: UUID) throws -> SourceMaterialContext? {
        guard let node = try nodeStore.fetchNode(id: nodeId),
              let metadata = try nodeStore.fetchSourceMetadata(nodeId: nodeId) else {
            return nil
        }
        let storedChunks = try nodeStore.fetchSourceChunks(nodeId: nodeId)
        let chunks = storedChunks
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
            chunks: Array(chunks),
            summaryMap: SourceSummaryMapBuilder.build(
                kind: metadata.kind,
                originalFilename: metadata.originalFilename,
                text: node.content,
                chunks: Array(storedChunks)
            ),
            evidenceLevel: metadata.evidenceLevel
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
