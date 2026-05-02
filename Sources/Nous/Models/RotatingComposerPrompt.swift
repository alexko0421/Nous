import Foundation

struct RotatingComposerPrompt {
    static let defaultPrompts = [
        "What are we thinking about tonight?",
        "What is still unresolved?",
        "What changed today?",
        "Where should we look closer?",
        "Start with the messy version."
    ]

    let prompts: [String]

    init(prompts: [String] = Self.defaultPrompts) {
        self.prompts = prompts.isEmpty ? Self.defaultPrompts : prompts
    }

    func text(at index: Int) -> String {
        prompts[normalized(index)]
    }

    func nextIndex(after index: Int) -> Int {
        (normalized(index) + 1) % prompts.count
    }

    func shouldShow(inputText: String) -> Bool {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func shouldAdvance(inputText: String, isFocused: Bool) -> Bool {
        shouldShow(inputText: inputText) && !isFocused
    }

    private func normalized(_ index: Int) -> Int {
        let remainder = index % prompts.count
        return remainder >= 0 ? remainder : remainder + prompts.count
    }
}
