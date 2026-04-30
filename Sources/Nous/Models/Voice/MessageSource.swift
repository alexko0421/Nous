import Foundation

/// Origin of a chat message. Determines whether the bubble renders a mic icon
/// next to the timestamp. Persisted as the `source` column in `messages`.
enum MessageSource: String, Codable, Equatable {
    case typed
    case voice
}
