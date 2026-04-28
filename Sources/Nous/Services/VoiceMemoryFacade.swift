import Foundation

private protocol VoiceRecentConversationMemoryProviding {
    func fetchMemoryEntries() throws -> [MemoryEntry]
    func fetchNode(id: UUID) throws -> NousNode?
}

extension NodeStore: VoiceRecentConversationMemoryProviding {}

protocol VoiceMemorySearching {
    func searchMemory(query: String, limit: Int, context: VoiceMemoryContext) throws -> String
    func recallRecentConversations(limit: Int, context: VoiceMemoryContext) throws -> String
}

struct VoiceMemoryContext: Equatable {
    let projectId: UUID?
    let conversationId: UUID
}

final class VoiceMemoryFacade: VoiceMemorySearching {
    private let memorySearchProvider: any MemoryEntrySearchProviding
    private let recentProvider: any VoiceRecentConversationMemoryProviding
    private let maxCharacters: Int

    init(nodeStore: NodeStore, maxCharacters: Int = 1200) {
        self.memorySearchProvider = nodeStore
        self.recentProvider = nodeStore
        self.maxCharacters = maxCharacters
    }

    func searchMemory(query: String, limit: Int, context: VoiceMemoryContext) throws -> String {
        let normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedQuery.isEmpty else { return "No matching memory found." }

        let entries = try memorySearchProvider.searchActiveMemoryEntries(
            query: normalizedQuery,
            projectId: context.projectId,
            conversationId: context.conversationId,
            limit: clampedLimit(limit)
        )
        guard !entries.isEmpty else { return "No matching memory found." }

        let output = entries
            .map { "- \($0.kind.rawValue): \(trimmed($0.content))" }
            .joined(separator: "\n")
        return clampedOutput(output)
    }

    func recallRecentConversations(limit: Int, context: VoiceMemoryContext) throws -> String {
        let memories = try recentConversationMemories(limit: clampedLimit(limit), context: context)
        guard !memories.isEmpty else { return "No recent conversations found." }

        let output = memories
            .map { "- \(trimmed($0.title)): \(prefix($0.memory, maxCharacters: 360))" }
            .joined(separator: "\n")
        return clampedOutput(output)
    }

    private func recentConversationMemories(
        limit: Int,
        context: VoiceMemoryContext
    ) throws -> [(title: String, memory: String)] {
        let entries = try recentProvider.fetchMemoryEntries()
        var memories: [(title: String, memory: String, updatedAt: Date)] = []

        for entry in entries {
            guard entry.status == .active,
                  entry.scope == .conversation,
                  let scopeRefId = entry.scopeRefId,
                  scopeRefId != context.conversationId,
                  !trimmed(entry.content).isEmpty else {
                continue
            }
            guard let node = try recentProvider.fetchNode(id: scopeRefId),
                  node.type == .conversation else {
                continue
            }

            if let projectId = context.projectId {
                guard node.projectId == projectId else { continue }
            } else {
                guard node.projectId == nil else { continue }
            }

            memories.append((title: node.title, memory: entry.content, updatedAt: entry.updatedAt))
        }

        return memories
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(limit)
            .map { (title: $0.title, memory: $0.memory) }
    }

    private func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, 1), 5)
    }

    private func clampedOutput(_ value: String) -> String {
        guard value.count > maxCharacters else { return value }
        guard maxCharacters > 3 else { return String("...".prefix(maxCharacters)) }
        let prefixLength = maxCharacters - 3
        return String(value.prefix(prefixLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func prefix(_ value: String, maxCharacters: Int) -> String {
        let value = trimmed(value)
        guard value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
