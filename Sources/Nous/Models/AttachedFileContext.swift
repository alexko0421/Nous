import Foundation

struct AttachedFileContext: Identifiable, Equatable {
    let id: UUID
    let name: String
    let extractedText: String?
    let sourceText: String?

    init(
        id: UUID = UUID(),
        name: String,
        extractedText: String?,
        sourceText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.extractedText = extractedText
        self.sourceText = sourceText
    }
}
