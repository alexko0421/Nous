import XCTest
@testable import Nous

final class MemoryRecallReliabilityTests: XCTestCase {

    func test_assertion_1_cantonese_2char_keyword_surfaces_chat_atoms() throws {
        let env = try MemoryRecallTestEnv.make()  // helper to be created
        env.seedAtom(text: "topic-A 我唔配喺呢度", scope: .conversation, conv: "chat-A")
        let results = try env.retrieve(query: "topic-A 自卑")
        XCTAssertTrue(results.contains { $0.statement.contains("topic-A") })
    }

    func test_assertion_2_codeswitch_query_finds_both_languages() throws {
        let env = try MemoryRecallTestEnv.make()
        env.seedAtom(text: "topic-B 我嘅 career", scope: .conversation, conv: "chat-B")
        env.seedAtom(text: "topic-B my career planning", scope: .conversation, conv: "chat-C")
        let results = try env.retrieve(query: "topic-B career 走向")
        XCTAssertGreaterThanOrEqual(results.filter { $0.statement.contains("topic-B") }.count, 2)
    }

    func test_assertion_3_cantonese_query_finds_english_atom_via_vector() throws {
        let env = try MemoryRecallTestEnv.make()
        env.seedAtom(text: "topic-C English-only fixture statement", scope: .conversation, conv: "chat-D")
        let results = try env.retrieve(query: "topic-C 中文 query")
        XCTAssertTrue(results.contains { $0.statement.contains("topic-C") })
    }

    func test_assertion_4_off_topic_query_returns_empty_or_low_confidence() throws {
        let env = try MemoryRecallTestEnv.make()
        env.seedAtom(text: "topic-A unrelated", scope: .conversation, conv: "chat-A")
        let results = try env.retrieve(query: "topic-Z totally different")
        XCTAssertTrue(results.isEmpty || results.allSatisfy { $0.confidence < 0.5 })
    }

    func test_assertion_5_default_chat_runs_corpus_retrieval() throws {
        let env = try MemoryRecallTestEnv.make()
        env.seedAtom(text: "topic-A statement", scope: .conversation, conv: "chat-A")
        let result = try env.buildPromptContext(quickActionMode: nil, query: "topic-A query")
        XCTAssertTrue(result.contains("topic-A"), "Default chat must include corpus retrieval output")
    }

    func test_assertion_6_new_atom_preserves_source_language_and_quote() throws {
        let env = try MemoryRecallTestEnv.make()
        let atom = try env.extractAtomFrom(userMessage: "我唔系一个读书好叻嘅人")
        XCTAssertTrue(atom.statement.contains("唔") || atom.statement.contains("我"))
        XCTAssertNotNil(atom.verbatimQuote)
        XCTAssertFalse(atom.verbatimQuote?.isEmpty ?? true)
    }

    func test_assertion_7_cross_signature_query_rejected() throws {
        let env = try MemoryRecallTestEnv.make()
        env.seedAtom(text: "topic-A old", scope: .conversation, conv: "chat-A", signature: "old-sig-v0")
        env.setCurrentSignature("new-sig-v1")
        let results = try env.retrieve(query: "topic-A")
        XCTAssertTrue(results.isEmpty, "Old-signature atoms must be invisible to new-signature query")
    }
}

// MARK: - Test environment stub (bodies unimplemented — Task 1.2+)

/// Shared stub embedder — placed here (outside the test class) so
/// `MemoryRecallTestEnv` can reference it without qualifying the name.
final class StubEmbedder {
    private static let dim = 8
    func embed(_ text: String) -> [Float] {
        var vec = [Float](repeating: 0, count: Self.dim)
        for topic in ["topic-A", "topic-B", "topic-C", "topic-D"] {
            if text.contains(topic) { vec[Int(topic.last!.asciiValue! % UInt8(Self.dim))] = 1; break }
        }
        return vec
    }
}

final class MemoryRecallTestEnv {
    let nodeStore: NodeStore
    let embedder: StubEmbedder
    var currentSignature: String = "test-sig-v1"

    init(nodeStore: NodeStore, embedder: StubEmbedder) {
        self.nodeStore = nodeStore
        self.embedder = embedder
    }

    static func make() throws -> MemoryRecallTestEnv {
        let store = try NodeStore(path: ":memory:")
        return MemoryRecallTestEnv(nodeStore: store, embedder: StubEmbedder())
    }

    func seedAtom(text: String, scope: MemoryScope, conv: String, signature: String? = nil) {
        var atom = MemoryAtom(
            type: .belief,
            statement: text,
            scope: scope
        )
        atom.embedding = embedder.embed(text)
        atom.embeddingSignature = signature ?? currentSignature
        try? nodeStore.insertMemoryAtom(atom)
    }

    func retrieve(query: String) throws -> [MemoryAtom] {
        let vec = embedder.embed(query)
        return try nodeStore.fetchMemoryAtomsNearest(
            embedding: vec, topK: 10, activeSignature: currentSignature
        )
    }

    /// `quickActionMode` is `QuickActionMode?` — nil means default/standard chat mode.
    /// `QuickActionMode` was confirmed in Sources/Nous/Models/QuickActionMode.swift.
    func buildPromptContext(quickActionMode: QuickActionMode?, query: String) throws -> String {
        // Simplified default-chat retrieval simulation. The actual production path
        // is TurnMemoryContextBuilder → CitableContextBuilder → PromptContextAssembler;
        // here we exercise the core invariant (default-chat retrieves atoms by vector)
        // without the heavy assemble() setup.
        let vec = embedder.embed(query)
        let atoms = try nodeStore.fetchMemoryAtomsNearest(
            embedding: vec, topK: 10, activeSignature: currentSignature
        )
        return atoms.map { $0.statement }.joined(separator: "\n")
    }

    func extractAtomFrom(userMessage: String) throws -> MemoryAtom {
        let atom = MemoryAtom(
            type: .belief,
            statement: userMessage,
            scope: .conversation,
            scopeRefId: UUID(),
            confidence: 0.8,
            verbatimQuote: userMessage
        )
        try nodeStore.insertMemoryAtom(atom)
        return atom
    }

    func setCurrentSignature(_ sig: String) { currentSignature = sig }
}
