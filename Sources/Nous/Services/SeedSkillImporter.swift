import Foundation

struct SeedSkillRow: Codable, Equatable {
    let id: UUID
    let userId: String
    let payload: SkillPayload
    let state: SkillState
}

enum SeedSkillImporterError: LocalizedError {
    case seedFileMissing(String)

    var errorDescription: String? {
        switch self {
        case .seedFileMissing(let resourceName):
            return "Seed skill file \(resourceName).json was not found in the bundle."
        }
    }
}

final class SeedSkillImporter {
    private let store: SkillStoring
    private let bundle: Bundle
    private let resourceName: String

    init(
        store: SkillStoring,
        bundle: Bundle = .main,
        resourceName: String = "seed-skills"
    ) {
        self.store = store
        self.bundle = bundle
        self.resourceName = resourceName
    }

    func importSeeds() throws {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw SeedSkillImporterError.seedFileMissing(resourceName)
        }

        let rows = try JSONDecoder().decode([SeedSkillRow].self, from: Data(contentsOf: url))
        let importedAt = Date()

        for row in rows {
            if try store.fetchSkill(id: row.id) != nil {
                continue
            }

            let skill = Skill(
                id: row.id,
                userId: row.userId,
                payload: row.payload,
                state: row.state,
                firedCount: 0,
                createdAt: importedAt,
                lastModifiedAt: importedAt,
                lastFiredAt: nil
            )

            do {
                try store.insertSkill(skill)
            } catch {
                if try store.fetchSkill(id: row.id) != nil {
                    continue
                }
                throw error
            }
        }
    }
}
