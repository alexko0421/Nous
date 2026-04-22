import Foundation

/// A snapshot of an LLM-generated summary captured from a Nous assistant reply.
/// The `markdown` is the inner content of a <summary>…</summary> block; the tag
/// markers themselves are stripped before storage.
struct ScratchSummary: Codable, Equatable {
    let markdown: String
    let generatedAt: Date
    let sourceMessageId: UUID
}
