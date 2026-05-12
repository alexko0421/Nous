import Foundation

enum ThumbVerdict: String, Codable {
    case up
    case down
    case unset
}

enum JudgePath: String, Codable {
    case atom
    case llm
    case fallback
    case retrieval
}
