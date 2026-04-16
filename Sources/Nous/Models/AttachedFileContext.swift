import Foundation

struct AttachedFileContext: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let extractedText: String?
}
