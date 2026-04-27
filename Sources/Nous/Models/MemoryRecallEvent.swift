import Foundation

struct MemoryRecallEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let query: String
    var intent: String?
    var timeWindowStart: Date?
    var timeWindowEnd: Date?
    var retrievedAtomIds: [UUID]
    var answerSummary: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        query: String,
        intent: String? = nil,
        timeWindowStart: Date? = nil,
        timeWindowEnd: Date? = nil,
        retrievedAtomIds: [UUID] = [],
        answerSummary: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.query = query
        self.intent = intent
        self.timeWindowStart = timeWindowStart
        self.timeWindowEnd = timeWindowEnd
        self.retrievedAtomIds = retrievedAtomIds
        self.answerSummary = answerSummary
        self.createdAt = createdAt
    }
}
