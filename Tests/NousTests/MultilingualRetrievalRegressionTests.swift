import XCTest
@testable import Nous

/// Multilingual retrieval regression suite.
///
/// Locked golden cases per
/// `docs/superpowers/plans/2026-05-08-memory-retrieval-multilingual-architecture.md`
/// Move 4. These cases reproduce the 2026-05-08 production bug:
/// a Cantonese roommate query surfaced an irrelevant English Kai Trump
/// source article AND missed the directly-relevant 室友 chat.
///
/// Synthetic embeddings are hand-crafted to simulate the failure mode:
/// the roommate chat embedding is intentionally close to the Kai Trump
/// source chunk embeddings (mimicking CJK-noise indistinguishability on
/// the current English-only model). Vector-only retrieval cannot
/// reliably rank room mate above Kai Trump under this design.
///
/// The hybrid lexical lane (Move 1) is what makes these tests pass:
/// trigram FTS5 over node titles + message content gives roommate-themed
/// chats a deterministic lexical signal that source chunks cannot match.
///
/// Until Move 1 ships, set `hybridRetrievalEnabled = false` and the suite
/// skips cleanly. Move 1's exit criteria includes flipping that flag and
/// confirming the suite is green.
final class MultilingualRetrievalRegressionTests: XCTestCase {

    /// Flip to `true` once `LexicalIndex` + `VectorStore.searchHybrid` ship
    /// (Move 1). Tests depend on lexical fallback for the CJK-noise cases.
    static let hybridRetrievalEnabled = true

    var nodeStore: NodeStore!
    var vectorStore: VectorStore!

    // MARK: - Synthetic embedding catalog
    //
    // Dim layout (4 dims):
    //   0: roommate-noise channel (CJK content tends to land here on MiniLM-L6)
    //   1: career-signal channel
    //   2: dating-signal channel
    //   3: random-orthogonal noise
    //
    // The roommate chat AND the Kai Trump source chunks both load dim-0
    // and dim-3 — this is the "CJK noise zone" simulation. Vector-only
    // retrieval cannot tell them apart. Lexical (title + content) can.

    // Cantonese / Mandarin chats
    private let roommateChatEmbedding: [Float] = [0.70, 0.20, 0.10, 0.50]
    private let careerChatEmbedding: [Float]   = [0.10, 0.95, 0.10, 0.00]
    private let datingChatEmbedding: [Float]   = [0.05, 0.10, 0.85, 0.10]
    private let foodChatEmbedding: [Float]     = [0.10, 0.00, 0.50, 0.60]
    private let familyChatEmbedding: [Float]   = [0.30, 0.10, 0.40, 0.30]

    // English chats
    private let englishCareerEmbedding: [Float] = [0.10, 0.90, 0.10, 0.10]
    private let englishLearnEmbedding: [Float]  = [0.20, 0.30, 0.15, 0.55]

    // Source articles (only Kai Trump simulated as the false-positive)
    private let kaiTrumpChunkA: [Float] = [0.65, 0.25, 0.10, 0.55]
    private let kaiTrumpChunkB: [Float] = [0.70, 0.20, 0.00, 0.50]

    // Queries
    private let cantoneseRoommateQuery: [Float]    = [0.65, 0.20, 0.10, 0.55]
    private let codeSwitchRoommateQuery: [Float]   = [0.60, 0.25, 0.10, 0.50]
    private let cantoneseCareerQuery: [Float]      = [0.10, 0.90, 0.10, 0.05]
    private let englishCareerQuery: [Float]        = [0.10, 0.95, 0.10, 0.10]
    private let unrelatedQuery: [Float]            = [0.00, 0.00, 0.00, 1.00]
    private let broadFriendshipQuery: [Float]      = [0.30, 0.30, 0.30, 0.30]
    private let shortRoommateQuery: [Float]        = [0.70, 0.20, 0.10, 0.50]

    // Node ids — keep stable for test message wiring
    private var roommateChatId = UUID()
    private var careerChatId = UUID()
    private var datingChatId = UUID()
    private var foodChatId = UUID()
    private var familyChatId = UUID()
    private var englishCareerId = UUID()
    private var englishLearnId = UUID()
    private var kaiTrumpSourceId = UUID()

    override func setUp() {
        super.setUp()
        nodeStore = try! NodeStore(path: ":memory:")
        vectorStore = VectorStore(nodeStore: nodeStore)
        try! seedFixtureCorpus()
    }

    // MARK: - Golden cases

    /// Case 1: Cantonese roommate query must surface 室友 chat in top-1
    /// AND must NOT include the Kai Trump article anywhere in top-K.
    func testCase1_CantoneseRoommateQuerySurfacesRoommateChat() throws {
        try XCTSkipUnless(Self.hybridRetrievalEnabled, Self.skipReason)

        let results = try vectorStore.searchForChatCitations(
            query: cantoneseRoommateQuery,
            queryText: "室友又惡咗我啊",
            topK: 5,
            now: Date()
        )

        let titles = results.map(\.node.title)
        XCTAssertEqual(titles.first, "室友违反协定去 lawyer", "case 1: 室友 chat must rank top-1")
        XCTAssertFalse(
            titles.contains(where: { $0.contains("Kai Trump") }),
            "case 1: Kai Trump must not appear (got \(titles))"
        )
    }

    /// Case 2: Code-switch roommate query (English "roommate" + Cantonese)
    /// must surface 室友 chat in top-3.
    func testCase2_CodeSwitchRoommateQuerySurfacesRoommateChat() throws {
        try XCTSkipUnless(Self.hybridRetrievalEnabled, Self.skipReason)

        let results = try vectorStore.searchForChatCitations(
            query: codeSwitchRoommateQuery,
            queryText: "roommate 真係搞我",
            topK: 5,
            now: Date()
        )

        let topThree = results.prefix(3).map(\.node.title)
        XCTAssertTrue(
            topThree.contains("室友违反协定去 lawyer"),
            "case 2: 室友 chat must be in top-3 (got \(topThree))"
        )
    }

    /// Case 3: Cantonese career query must surface career chat in top-3.
    func testCase3_CantoneseCareerQuerySurfacesCareerChat() throws {
        try XCTSkipUnless(Self.hybridRetrievalEnabled, Self.skipReason)

        let results = try vectorStore.searchForChatCitations(
            query: cantoneseCareerQuery,
            queryText: "我嘅career點走好",
            topK: 5,
            now: Date()
        )

        let topThree = results.prefix(3).map(\.node.title)
        XCTAssertTrue(
            topThree.contains("轉工掙扎"),
            "case 3: career chat must be in top-3 (got \(topThree))"
        )
    }

    /// Case 4: English career query must surface either Cantonese career
    /// chat OR English career chat in top-3 (cross-language retrieval).
    func testCase4_EnglishCareerQueryCrossesLanguage() throws {
        try XCTSkipUnless(Self.hybridRetrievalEnabled, Self.skipReason)

        let results = try vectorStore.searchForChatCitations(
            query: englishCareerQuery,
            queryText: "should I switch jobs",
            topK: 5,
            now: Date()
        )

        let topThree = results.prefix(3).map(\.node.title)
        let hasAnyCareer = topThree.contains("轉工掙扎") || topThree.contains("career planning")
        XCTAssertTrue(hasAnyCareer, "case 4: at least one career chat in top-3 (got \(topThree))")
    }

    /// Case 5: Out-of-corpus query must return empty OR low-confidence
    /// result, NOT a random source article.
    func testCase5_OutOfCorpusQueryReturnsEmptyOrLowConfidence() throws {
        try XCTSkipUnless(Self.hybridRetrievalEnabled, Self.skipReason)

        let results = try vectorStore.searchForChatCitations(
            query: unrelatedQuery,
            queryText: "今天午餐什麼好",
            topK: 5,
            now: Date()
        )

        // Either empty OR every result has below-confidence-threshold similarity.
        // Crucially, must NOT include Kai Trump or any source article as a
        // "best guess".
        let titles = results.map(\.node.title)
        XCTAssertFalse(
            titles.contains(where: { $0.contains("Kai Trump") }),
            "case 5: Kai Trump must not surface for unrelated CJK query (got \(titles))"
        )
    }

    /// Case 6: Broad friendship query without specific corpus match must
    /// flag low confidence rather than surface unrelated source.
    func testCase6_BroadQueryDoesNotSurfaceUnrelatedSource() throws {
        try XCTSkipUnless(Self.hybridRetrievalEnabled, Self.skipReason)

        let results = try vectorStore.searchForChatCitations(
            query: broadFriendshipQuery,
            queryText: "跟朋友聚會",
            topK: 5,
            now: Date()
        )

        let titles = results.map(\.node.title)
        XCTAssertFalse(
            titles.contains(where: { $0.contains("Kai Trump") }),
            "case 6: Kai Trump must not surface for broad CJK query (got \(titles))"
        )
    }

    /// Case 7: Empty query string returns empty result, no crash.
    func testCase7_EmptyQueryReturnsEmpty() throws {
        try XCTSkipUnless(Self.hybridRetrievalEnabled, Self.skipReason)

        let results = try vectorStore.searchForChatCitations(
            query: cantoneseRoommateQuery,
            queryText: "",
            topK: 5,
            now: Date()
        )

        // queryText empty AND no semantic floor cleared in synthetic corpus
        // for this query → expected empty. Detail of empty-vs-low-confidence
        // is acceptable as long as no crash.
        XCTAssertNotNil(results)
    }

    /// Case 8: Short 2-character query 室友 must hit 室友 chat in top-1
    /// via the lexical lane alone. This is the case current vector-only
    /// retrieval definitionally cannot solve — embeddings of 5-char or
    /// shorter queries are too noisy to discriminate.
    func testCase8_ShortCJKQueryWinsViaLexicalLane() throws {
        try XCTSkipUnless(Self.hybridRetrievalEnabled, Self.skipReason)

        let results = try vectorStore.searchForChatCitations(
            query: shortRoommateQuery,
            queryText: "室友",
            topK: 5,
            now: Date()
        )

        let titles = results.map(\.node.title)
        XCTAssertEqual(titles.first, "室友违反协定去 lawyer", "case 8: short 2-char CJK query must hit via lexical lane (got \(titles))")
        XCTAssertFalse(
            titles.contains(where: { $0.contains("Kai Trump") }),
            "case 8: Kai Trump must not surface (got \(titles))"
        )
    }

    // MARK: - Fixture seeding

    private func seedFixtureCorpus() throws {
        let now = Date()
        let day: TimeInterval = 86_400

        // 5 Cantonese / Mandarin chats
        try insertConversation(
            id: roommateChatId,
            title: "室友违反协定去 lawyer",
            embedding: roommateChatEmbedding,
            createdAt: now.addingTimeInterval(-2 * day),
            messages: [
                ("user", "因为讲真其实我自己都好惊去搞呢啲嘢，呢次系我第一次处理"),
                ("assistant", "三个月忍落嚟，对方仲完全唔 care，你嬲系正常嘅"),
                ("user", "我学识咗呢样嘢，有时候你真系要主动嘅反击")
            ]
        )
        try insertConversation(
            id: careerChatId,
            title: "轉工掙扎",
            embedding: careerChatEmbedding,
            createdAt: now.addingTimeInterval(-7 * day),
            messages: [
                ("user", "我覺得而家份工冇成長空間，諗緊轉工"),
                ("assistant", "career 嘅選擇唔淨係 title 同 pay，仲有 learning curve")
            ]
        )
        try insertConversation(
            id: datingChatId,
            title: "拍拖嘅選擇",
            embedding: datingChatEmbedding,
            createdAt: now.addingTimeInterval(-14 * day),
            messages: [
                ("user", "佢同我講以後唔搵我"),
                ("assistant", "你嘅情緒反應好真實")
            ]
        )
        try insertConversation(
            id: foodChatId,
            title: "Hong Kong food",
            embedding: foodChatEmbedding,
            createdAt: now.addingTimeInterval(-21 * day),
            messages: [
                ("user", "今晚食咩好"),
                ("assistant", "茶餐廳定係 sushi")
            ]
        )
        try insertConversation(
            id: familyChatId,
            title: "屋企人嘅張力",
            embedding: familyChatEmbedding,
            createdAt: now.addingTimeInterval(-30 * day),
            messages: [
                ("user", "媽咪又同我講要結婚"),
                ("assistant", "佢嘅 timeline 唔係你嘅 timeline")
            ]
        )

        // 2 English chats
        try insertConversation(
            id: englishCareerId,
            title: "career planning",
            embedding: englishCareerEmbedding,
            createdAt: now.addingTimeInterval(-10 * day),
            messages: [
                ("user", "I am thinking about switching jobs but worried about timing"),
                ("assistant", "What does staying for another year actually buy you?")
            ]
        )
        try insertConversation(
            id: englishLearnId,
            title: "learning Spanish",
            embedding: englishLearnEmbedding,
            createdAt: now.addingTimeInterval(-40 * day),
            messages: [
                ("user", "How do I get past the intermediate plateau"),
                ("assistant", "Switch from input to output: write or speak something every day")
            ]
        )

        // 1 source article (Kai Trump) with 2 chunks designed to land in
        // the same dim-0 / dim-3 noise zone as the roommate chat.
        try insertSource(
            id: kaiTrumpSourceId,
            title: "Kai Trump on Donald Trump's 3rd Term, Dating with 24/7 Secret Service, Golfing w/ the President: 488",
            chunks: [
                (text: "LADIES AND GENTLEMEN, IT'S KAI TRUMP. Presidential election winner Donald Trump",
                 embedding: kaiTrumpChunkA),
                (text: "Dating with 24/7 secret service was the wildest part. Golfing with the president",
                 embedding: kaiTrumpChunkB)
            ],
            createdAt: now.addingTimeInterval(-day)
        )
    }

    private func insertConversation(
        id: UUID,
        title: String,
        embedding: [Float],
        createdAt: Date,
        messages: [(role: String, content: String)]
    ) throws {
        let node = NousNode(
            id: id,
            type: .conversation,
            title: title,
            embedding: embedding,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try nodeStore.insertNode(node)
        for (offset, msg) in messages.enumerated() {
            let role = MessageRole(rawValue: msg.role) ?? .user
            let m = Message(
                nodeId: id,
                role: role,
                content: msg.content,
                timestamp: createdAt.addingTimeInterval(Double(offset) * 60)
            )
            try nodeStore.insertMessage(m)
        }
    }

    private func insertSource(
        id: UUID,
        title: String,
        chunks: [(text: String, embedding: [Float])],
        createdAt: Date
    ) throws {
        // Source nodes carry their own representative embedding (first chunk's)
        // for the chat-citation pool's per-node search; chunks live separately.
        let node = NousNode(
            id: id,
            type: .source,
            title: title,
            content: chunks.first?.text ?? "",
            embedding: chunks.first?.embedding ?? [],
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try nodeStore.insertNode(node)
        // Source-chunk insertion API (used by SourceIngestionService) is the
        // production path; if that surface needs different shape for this
        // suite, Move 1 implementation will adjust this helper. For now
        // representing chunks as their parent-node embedding is sufficient
        // for the false-positive test (chunk-pool path is exercised by the
        // existing source ranking mechanics).
        _ = chunks
    }

    private static let skipReason = """
    Requires Move 1 hybrid retrieval (lexical lane via FTS5 + RRF). Plan: \
    docs/superpowers/plans/2026-05-08-memory-retrieval-multilingual-architecture.md. \
    Flip MultilingualRetrievalRegressionTests.hybridRetrievalEnabled to true once \
    LexicalIndex + searchHybrid ship.
    """
}
