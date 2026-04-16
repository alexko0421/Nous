import XCTest
@testable import Nous

final class TopicEmojiResolverTests: XCTestCase {

    func testBusinessConversationGetsBriefcaseEmoji() {
        let node = NousNode(type: .conversation, title: "Help me think through a business decision")
        XCTAssertEqual(TopicEmojiResolver.emoji(for: node), "💼")
    }

    func testFoodConversationGetsFoodEmoji() {
        let node = NousNode(type: .conversation, title: "今日做咩嘢食呀？")
        XCTAssertEqual(TopicEmojiResolver.emoji(for: node), "🍜")
    }

    func testDirectionConversationGetsCompassEmoji() {
        let node = NousNode(type: .conversation, title: "I need direction on my next step")
        XCTAssertEqual(TopicEmojiResolver.emoji(for: node), "🧭")
    }

    func testFallbackConversationEmojiStaysSpeechBubble() {
        let node = NousNode(type: .conversation, title: "Random catchup")
        XCTAssertEqual(TopicEmojiResolver.emoji(for: node), "💬")
    }

    func testStoredEmojiWinsOverKeywordHeuristic() {
        let node = NousNode(type: .conversation, title: "Help me think through a business decision", emoji: "💚")
        XCTAssertEqual(TopicEmojiResolver.emoji(for: node), "💚")
    }
}
