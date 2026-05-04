import Foundation

protocol SkillTracking {
    func recordFire(skillIds: [UUID]) async throws
}

final class SkillTracker: SkillTracking {
    private let store: SkillStoring

    init(store: SkillStoring) {
        self.store = store
    }

    func recordFire(skillIds: [UUID]) async throws {
        for skillId in skillIds {
            do {
                try store.incrementFiredCount(id: skillId, firedAt: Date())
            } catch {
                print("[SkillTracker] failed to record skill fire \(skillId): \(error)")
            }
        }
    }
}
