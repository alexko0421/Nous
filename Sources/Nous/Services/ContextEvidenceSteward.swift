import Foundation

final class ContextEvidenceSteward {
    typealias RecentConversation = (title: String, memory: String)

    func filterMemoryEvidence(
        _ evidence: [MemoryEvidenceSnippet],
        promptQuery: String
    ) -> (kept: [MemoryEvidenceSnippet], assessment: ContextEvidenceAssessment) {
        var kept: [MemoryEvidenceSnippet] = []
        var drops: [ContextEvidenceDrop] = []

        for item in evidence {
            let label = item.label
            let text = "\(item.sourceTitle) \(item.snippet)"
            if item.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                drops.append(ContextEvidenceDrop(role: .contextEvidenceSteward, label: label, reason: .empty))
            } else if Self.hasOverlap(text, promptQuery) {
                kept.append(item)
            } else {
                drops.append(ContextEvidenceDrop(role: .contextEvidenceSteward, label: label, reason: .offTopic))
            }
        }

        return (
            kept,
            ContextEvidenceAssessment(
                role: .contextEvidenceSteward,
                keptLabels: kept.map(\.label),
                drops: drops
            )
        )
    }

    func filterRecentConversations(
        _ conversations: [RecentConversation],
        promptQuery: String
    ) -> (kept: [RecentConversation], assessment: ContextEvidenceAssessment) {
        var kept: [RecentConversation] = []
        var drops: [ContextEvidenceDrop] = []

        for conversation in conversations {
            let label = conversation.title
            let text = "\(conversation.title) \(conversation.memory)"
            if conversation.memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                drops.append(ContextEvidenceDrop(role: .contextEvidenceSteward, label: label, reason: .empty))
            } else if Self.hasOverlap(text, promptQuery) {
                kept.append(conversation)
            } else {
                drops.append(ContextEvidenceDrop(role: .contextEvidenceSteward, label: label, reason: .offTopic))
            }
        }

        return (
            kept,
            ContextEvidenceAssessment(
                role: .contextEvidenceSteward,
                keptLabels: kept.map { $0.title },
                drops: drops
            )
        )
    }

    private static func hasOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedTokens(lhs)
        let right = normalizedTokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return !left.intersection(right).isEmpty
    }

    private static func normalizedTokens(_ text: String) -> Set<String> {
        let stopwords: Set<String> = ["the", "and", "for", "with", "this", "that", "after", "about", "alex"]
        let latinTokens = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0) }
            .filter { $0.count >= 3 && !stopwords.contains($0) }
            .filter { !$0.unicodeScalars.contains(where: isCJKScalar) }

        return Set(latinTokens + cjkPhraseTerms(from: text))
    }

    private static func cjkPhraseTerms(from text: String) -> [String] {
        var terms: [String] = []
        var chunk: [Character] = []

        func flushChunk() {
            guard chunk.count >= 2 else {
                chunk.removeAll()
                return
            }

            for width in 2...min(3, chunk.count) {
                guard chunk.count >= width else { continue }
                for index in 0...(chunk.count - width) {
                    let term = String(chunk[index..<(index + width)])
                    if !cjkStopwords.contains(term) {
                        terms.append(term)
                    }
                }
            }
            chunk.removeAll()
        }

        for character in text {
            if character.unicodeScalars.contains(where: isCJKScalar) {
                chunk.append(character)
            } else {
                flushChunk()
            }
        }
        flushChunk()

        return terms
    }

    private static let cjkStopwords: Set<String> = [
        "一个",
        "一個",
        "这个",
        "這個",
        "那个",
        "嗰個",
        "之前",
        "之后",
        "之後",
        "现在",
        "現在",
        "点样",
        "點樣",
        "系咪",
        "係咪"
    ]

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }
}
