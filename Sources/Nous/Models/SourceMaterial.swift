import Foundation

enum SourceKind: String, Codable, Equatable {
    case web
    case document
    case youtube
}

enum SourceExtractionStatus: String, Codable, Equatable {
    case ready
    case failed
}

enum SourceEvidenceLevel: String, Codable, Equatable {
    case transcriptBacked
    case geminiVideoAnalysis
    case summaryOnly
    case unknown

    var label: String {
        switch self {
        case .transcriptBacked:
            return "Transcript-backed"
        case .geminiVideoAnalysis:
            return "Gemini video analysis"
        case .summaryOnly:
            return "Summary-only"
        case .unknown:
            return "Unknown"
        }
    }

    var isQuoteLevelReliable: Bool {
        self == .transcriptBacked
    }
}

struct SourceMetadata: Equatable {
    let nodeId: UUID
    let kind: SourceKind
    let originalURL: String?
    let originalFilename: String?
    let contentHash: String
    let ingestedAt: Date
    let extractionStatus: SourceExtractionStatus
    let evidenceLevel: SourceEvidenceLevel

    init(
        nodeId: UUID,
        kind: SourceKind,
        originalURL: String?,
        originalFilename: String?,
        contentHash: String,
        ingestedAt: Date,
        extractionStatus: SourceExtractionStatus,
        evidenceLevel: SourceEvidenceLevel = .unknown
    ) {
        self.nodeId = nodeId
        self.kind = kind
        self.originalURL = originalURL
        self.originalFilename = originalFilename
        self.contentHash = contentHash
        self.ingestedAt = ingestedAt
        self.extractionStatus = extractionStatus
        self.evidenceLevel = evidenceLevel
    }
}

struct SourceChunk: Identifiable, Equatable {
    let id: UUID
    let sourceNodeId: UUID
    let ordinal: Int
    let text: String
    var embedding: [Float]?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sourceNodeId: UUID,
        ordinal: Int,
        text: String,
        embedding: [Float]? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceNodeId = sourceNodeId
        self.ordinal = ordinal
        self.text = text
        self.embedding = embedding
        self.createdAt = createdAt
    }
}

struct SourceChunkContext: Equatable, Codable {
    let sourceNodeId: UUID
    let ordinal: Int
    let text: String
    let similarity: Float?
}

struct SourceSummaryMapSection: Equatable, Codable {
    let partNumber: Int
    let title: String
    let summary: String
    let locatorLabel: String
    let evidenceExcerpt: String?

    init(
        partNumber: Int,
        title: String,
        summary: String,
        locatorLabel: String,
        evidenceExcerpt: String? = nil
    ) {
        self.partNumber = partNumber
        self.title = title
        self.summary = summary
        self.locatorLabel = locatorLabel
        self.evidenceExcerpt = evidenceExcerpt
    }
}

struct SourceSummaryMap: Equatable, Codable {
    let sections: [SourceSummaryMapSection]

    init(sections: [SourceSummaryMapSection]) {
        self.sections = sections
    }

    var isEmpty: Bool {
        sections.isEmpty
    }
}

struct SourceMaterialContext: Equatable, Codable {
    let sourceNodeId: UUID
    let title: String
    let originalURL: String?
    let originalFilename: String?
    let chunks: [SourceChunkContext]
    let summaryMap: SourceSummaryMap?
    let evidenceLevel: SourceEvidenceLevel

    init(
        sourceNodeId: UUID,
        title: String,
        originalURL: String?,
        originalFilename: String?,
        chunks: [SourceChunkContext],
        summaryMap: SourceSummaryMap? = nil,
        evidenceLevel: SourceEvidenceLevel = .unknown
    ) {
        self.sourceNodeId = sourceNodeId
        self.title = title
        self.originalURL = originalURL
        self.originalFilename = originalFilename
        self.chunks = chunks
        self.summaryMap = summaryMap
        self.evidenceLevel = evidenceLevel
    }

    var displaySource: String {
        originalURL ?? originalFilename ?? title
    }

    var previewLine: String {
        for chunk in chunks {
            let line = chunk.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            if !line.isEmpty { return line }
        }
        return title
    }
}

enum SourceSummaryMapBuilder {
    static func build(
        kind: SourceKind,
        originalFilename: String?,
        text: String,
        chunks: [SourceChunk]
    ) -> SourceSummaryMap? {
        guard kind == .document else { return nil }
        if isMarkdownFilename(originalFilename),
           let markdownMap = markdownHeadingMap(from: text),
           !markdownMap.isEmpty {
            return markdownMap
        }
        return chunkFallbackMap(from: chunks)
    }

    private static func isMarkdownFilename(_ filename: String?) -> Bool {
        guard let filename else { return false }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    private static func markdownHeadingMap(from text: String) -> SourceSummaryMap? {
        var drafts: [(marker: String, title: String, body: [String])] = []
        var current: (marker: String, title: String, body: [String])?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let heading = markdownHeading(in: trimmed) {
                if let current { drafts.append(current) }
                current = (heading.marker, heading.title, [])
            } else if var draft = current {
                draft.body.append(trimmed)
                current = draft
            }
        }
        if let current { drafts.append(current) }

        let sections = drafts.compactMap { draft -> SourceSummaryMapSection? in
            guard let evidence = firstMeaningfulLine(in: draft.body) else { return nil }
            return SourceSummaryMapSection(
                partNumber: 0,
                title: draft.title,
                summary: clipped(evidence),
                locatorLabel: "\(draft.marker) \(draft.title)",
                evidenceExcerpt: clipped(evidence)
            )
        }
        guard !sections.isEmpty else { return nil }
        return SourceSummaryMap(
            sections: sections.enumerated().map { index, section in
                SourceSummaryMapSection(
                    partNumber: index + 1,
                    title: section.title,
                    summary: section.summary,
                    locatorLabel: section.locatorLabel,
                    evidenceExcerpt: section.evidenceExcerpt
                )
            }
        )
    }

    private static func markdownHeading(in line: String) -> (marker: String, title: String)? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...3).contains(hashes.count),
              line.dropFirst(hashes.count).first == " " else {
            return nil
        }
        let title = line
            .dropFirst(hashes.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return (String(hashes), title)
    }

    private static func chunkFallbackMap(from chunks: [SourceChunk]) -> SourceSummaryMap? {
        let sections = chunks
            .prefix(3)
            .enumerated()
            .compactMap { offset, chunk -> SourceSummaryMapSection? in
                let lines = chunk.text
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard let evidence = firstMeaningfulLine(in: lines) else { return nil }
                return SourceSummaryMapSection(
                    partNumber: offset + 1,
                    title: "Part \(offset + 1)",
                    summary: clipped(evidence),
                    locatorLabel: "chunk \(chunk.ordinal + 1)",
                    evidenceExcerpt: clipped(evidence)
                )
            }
        return sections.isEmpty ? nil : SourceSummaryMap(sections: sections)
    }

    private static func firstMeaningfulLine(in lines: [String]) -> String? {
        lines.first { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && markdownHeading(in: trimmed) == nil
        }
    }

    private static func clipped(_ text: String, limit: Int = 320) -> String {
        let normalized = SourceTextExtractor.normalizeWhitespace(text)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SourceChunkSearchResult: Equatable {
    let sourceNode: NousNode
    let chunk: SourceChunk
    let similarity: Float

    static func == (lhs: SourceChunkSearchResult, rhs: SourceChunkSearchResult) -> Bool {
        lhs.sourceNode.id == rhs.sourceNode.id &&
        lhs.chunk == rhs.chunk &&
        lhs.similarity == rhs.similarity
    }
}
