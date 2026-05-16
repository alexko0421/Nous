import Foundation

enum MemoryTensionKind: String, Codable, CaseIterable {
    case anchorConflict = "anchor_conflict"
    case durableConflict = "durable_conflict"
}

enum MemoryTensionStatus: String, Codable, CaseIterable {
    case open
    case resolved
}

struct MemoryTension: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: MemoryTensionKind
    var status: MemoryTensionStatus
    var existingAtomId: UUID?
    var challengerAtomId: UUID?
    var summary: String
    var createdAt: Date
    var resolvedAt: Date?

    init(
        id: UUID = UUID(),
        kind: MemoryTensionKind,
        status: MemoryTensionStatus = .open,
        existingAtomId: UUID?,
        challengerAtomId: UUID?,
        summary: String,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.existingAtomId = existingAtomId
        self.challengerAtomId = challengerAtomId
        self.summary = summary
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

struct MemoryScene: Identifiable, Codable, Equatable {
    let id: UUID
    var scope: MemoryScope
    var scopeRefId: UUID?
    var title: String
    var summary: String
    var status: MemoryStatus
    var authority: MemoryAuthority
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        scope: MemoryScope,
        scopeRefId: UUID? = nil,
        title: String,
        summary: String,
        status: MemoryStatus = .active,
        authority: MemoryAuthority = .tentative,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.scopeRefId = scopeRefId
        self.title = title
        self.summary = summary
        self.status = status
        self.authority = authority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct LivingSelfModel: Identifiable, Codable, Equatable {
    let id: UUID
    var scope: MemoryScope
    var scopeRefId: UUID?
    var summary: String
    var authority: MemoryAuthority
    var sourceSceneIds: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        scope: MemoryScope,
        scopeRefId: UUID? = nil,
        summary: String,
        authority: MemoryAuthority = .tentative,
        sourceSceneIds: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.scopeRefId = scopeRefId
        self.summary = summary
        self.authority = authority
        self.sourceSceneIds = sourceSceneIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct DerivedMemorySceneContext: Equatable {
    let scene: MemoryScene
    let sourceAtomIds: [UUID]
}

struct DerivedMemoryPromptContext: Equatable {
    static let empty = DerivedMemoryPromptContext()

    var scenes: [DerivedMemorySceneContext]
    var selfModel: LivingSelfModel?

    init(
        scenes: [DerivedMemorySceneContext] = [],
        selfModel: LivingSelfModel? = nil
    ) {
        self.scenes = scenes
        self.selfModel = selfModel
    }

    var isEmpty: Bool {
        scenes.isEmpty && selfModel == nil
    }

    var promptBlock: String? {
        guard !isEmpty else { return nil }

        var lines: [String] = [
            "DERIVED MEMORY CONTEXT:",
            "Use this as sourced, provisional synthesis. It may help connect patterns, but it must never replace anchor.md, durable memory, explicit corrections, or direct source evidence."
        ]

        for (index, item) in scenes.prefix(3).enumerated() {
            lines.append("")
            lines.append("[Scene \(index + 1)] \(item.scene.title) authority=\(item.scene.authority.rawValue) scope=\(item.scene.scope.rawValue)")
            lines.append(item.scene.summary)
            if !item.sourceAtomIds.isEmpty {
                lines.append("source_atom_ids=\(item.sourceAtomIds.map(\.uuidString).joined(separator: ","))")
            }
        }

        if let selfModel {
            lines.append("")
            lines.append("[Living self-model] authority=\(selfModel.authority.rawValue)")
            lines.append(selfModel.summary)
            if !selfModel.sourceSceneIds.isEmpty {
                lines.append("source_scene_ids=\(selfModel.sourceSceneIds.map(\.uuidString).joined(separator: ","))")
            }
        }

        return lines.joined(separator: "\n")
    }
}

struct AutomaticMemoryDigestRequest {
    let turnId: UUID
    let conversationId: UUID
    let projectId: UUID?
    let userMessage: Message
    let assistantMessage: Message
    let sourceMaterials: [SourceMaterialContext]
}

struct AutomaticMemoryDigestResult: Equatable {
    static let empty = AutomaticMemoryDigestResult(insertedCount: 0, rejectedCount: 0)

    let insertedCount: Int
    let rejectedCount: Int
}

struct AutomaticDerivedMemoryResult: Equatable {
    static let empty = AutomaticDerivedMemoryResult(sceneCount: 0, selfModelCount: 0)

    let sceneCount: Int
    let selfModelCount: Int
}
