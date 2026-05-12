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

struct SourceMaterialContext: Equatable, Codable {
    let sourceNodeId: UUID
    let title: String
    let originalURL: String?
    let originalFilename: String?
    let chunks: [SourceChunkContext]
    let evidenceLevel: SourceEvidenceLevel

    init(
        sourceNodeId: UUID,
        title: String,
        originalURL: String?,
        originalFilename: String?,
        chunks: [SourceChunkContext],
        evidenceLevel: SourceEvidenceLevel = .unknown
    ) {
        self.sourceNodeId = sourceNodeId
        self.title = title
        self.originalURL = originalURL
        self.originalFilename = originalFilename
        self.chunks = chunks
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
