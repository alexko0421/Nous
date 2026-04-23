import XCTest
@testable import Nous

final class ConversationTitleBackfillServiceTests: XCTestCase {

    private final class FakeLLMService: LLMService {
        let output: String

        init(output: String) {
            self.output = output
        }

        func generate(messages: [LLMMessage], system: String?) async throws -> AsyncThrowingStream<String, Error> {
            let output = self.output
            return AsyncThrowingStream { continuation in
                continuation.yield(output)
                continuation.finish()
            }
        }
    }

    func testBackfillUsesLLMForLegacySeedTitles() async throws {
        let store = try NodeStore(path: ":memory:")
        let legacyPrompt = "其实你觉得系未来 AI 时代系咪生孩子真系冇有嗰么必要？"
        let legacyTitle = String(legacyPrompt.prefix(40))
        let chat = NousNode(type: .conversation, title: legacyTitle)
        try store.insertNode(chat)
        try store.insertMessage(Message(nodeId: chat.id, role: .user, content: legacyPrompt))
        try store.insertMessage(Message(nodeId: chat.id, role: .assistant, content: "我会由几个角度睇。"))
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: chat.id,
                kind: .thread,
                stability: .temporary,
                content: "- Alex 想搞清楚 AI 时代仲要唔要生细路",
                sourceNodeIds: [chat.id]
            )
        )

        let service = ConversationTitleBackfillService(
            nodeStore: store,
            llmServiceProvider: { FakeLLMService(output: "AI 时代仲要唔要生细路") }
        )

        await service.runIfNeeded()

        let updated = try XCTUnwrap(store.fetchNode(id: chat.id))
        XCTAssertEqual(updated.title, "AI 时代仲要唔要生细路")
        XCTAssertEqual(try schemaVersion(store), ConversationTitleBackfillService.targetVersion)
    }

    func testBackfillFallsBackToConversationMemoryWhenLLMUnavailable() async throws {
        let store = try NodeStore(path: ":memory:")
        let legacyPrompt = "Should I move to New York or Austin for the next phase?"
        let legacyTitle = String(legacyPrompt.prefix(40))
        let chat = NousNode(type: .conversation, title: legacyTitle)
        try store.insertNode(chat)
        try store.insertMessage(Message(nodeId: chat.id, role: .user, content: legacyPrompt))
        try store.insertMessage(Message(nodeId: chat.id, role: .assistant, content: "Let's compare both cities."))
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: chat.id,
                kind: .thread,
                stability: .temporary,
                content: "- Alex is deciding whether to move to New York or Austin",
                sourceNodeIds: [chat.id]
            )
        )

        let service = ConversationTitleBackfillService(
            nodeStore: store,
            llmServiceProvider: { nil }
        )

        await service.runIfNeeded()

        let updated = try XCTUnwrap(store.fetchNode(id: chat.id))
        XCTAssertEqual(updated.title, "move to New York or Austin")
        XCTAssertEqual(try schemaVersion(store), ConversationTitleBackfillService.targetVersion)
    }

    func testBackfillLeavesCuratedTitlesUntouched() async throws {
        let store = try NodeStore(path: ":memory:")
        let chat = NousNode(type: .conversation, title: "Future of Parenting")
        try store.insertNode(chat)
        try store.insertMessage(Message(nodeId: chat.id, role: .user, content: "其实你觉得系未来 AI 时代系咪生孩子真系冇有嗰么必要？"))
        try store.insertMessage(Message(nodeId: chat.id, role: .assistant, content: "我会直接答你。"))

        let service = ConversationTitleBackfillService(
            nodeStore: store,
            llmServiceProvider: { FakeLLMService(output: "AI 时代仲要唔要生细路") }
        )

        await service.runIfNeeded()

        let updated = try XCTUnwrap(store.fetchNode(id: chat.id))
        XCTAssertEqual(updated.title, "Future of Parenting")
        XCTAssertEqual(try schemaVersion(store), ConversationTitleBackfillService.targetVersion)
    }

    func testBackfillTreatsQuickActionTitlesAsPlaceholders() async throws {
        let store = try NodeStore(path: ":memory:")
        let chat = NousNode(type: .conversation, title: "Direction")
        try store.insertNode(chat)
        try store.insertMessage(Message(nodeId: chat.id, role: .assistant, content: "你而家最卡住边一步？"))
        try store.insertMemoryEntry(
            MemoryEntry(
                scope: .conversation,
                scopeRefId: chat.id,
                kind: .thread,
                stability: .temporary,
                content: "- Alex is deciding whether to move to New York or Austin",
                sourceNodeIds: [chat.id]
            )
        )

        let service = ConversationTitleBackfillService(
            nodeStore: store,
            llmServiceProvider: { FakeLLMService(output: "move to New York or Austin") }
        )

        await service.runIfNeeded()

        let updated = try XCTUnwrap(store.fetchNode(id: chat.id))
        XCTAssertEqual(updated.title, "move to New York or Austin")
        XCTAssertEqual(try schemaVersion(store), ConversationTitleBackfillService.targetVersion)
    }

    private func schemaVersion(_ store: NodeStore) throws -> String? {
        let stmt = try store.rawDatabase.prepare("SELECT value FROM schema_meta WHERE key = ?;")
        try stmt.bind(ConversationTitleBackfillService.versionKey, at: 1)
        guard try stmt.step() else { return nil }
        return stmt.text(at: 0)
    }
}
