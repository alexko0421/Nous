import Foundation

struct ClarificationCard: Equatable {
    let question: String
    let options: [String]
}

struct ClarificationContent: Equatable {
    let displayText: String
    let card: ClarificationCard?
    let keepsQuickActionMode: Bool
}
