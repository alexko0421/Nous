import Foundation

struct Project: Identifiable, Codable {
    let id: UUID
    var title: String
    var goal: String
    var emoji: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        goal: String = "",
        emoji: String = "📁",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.emoji = emoji
        self.createdAt = createdAt
    }
}
