import Foundation

enum SourceKind: String, Codable, Equatable {
    case web
    case document
}

enum SourceExtractionStatus: String, Codable, Equatable {
    case ready
    case failed
}

struct SourceMetadata: Equatable {
    let nodeId: UUID
    let kind: SourceKind
    let originalURL: String?
    let originalFilename: String?
    let contentHash: String
    let ingestedAt: Date
    let extractionStatus: SourceExtractionStatus
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

struct SourceChunkContext: Equatable {
    let sourceNodeId: UUID
    let ordinal: Int
    let text: String
    let similarity: Float?
}

struct SourceMaterialContext: Equatable {
    let sourceNodeId: UUID
    let title: String
    let originalURL: String?
    let originalFilename: String?
    let chunks: [SourceChunkContext]

    var displaySource: String {
        originalURL ?? originalFilename ?? title
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
