import Foundation

protocol SkillStoring {
    func fetchAllSkills(userId: String) throws -> [Skill]
    func fetchActiveSkills(userId: String) throws -> [Skill]
    func fetchSkill(id: UUID) throws -> Skill?
    func insertSkill(_ skill: Skill) throws
    func updateSkill(_ skill: Skill) throws
    func setSkillState(id: UUID, state: SkillState) throws
    func incrementFiredCount(id: UUID, firedAt: Date) throws
}

final class SkillStore: SkillStoring {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func fetchAllSkills(userId: String) throws -> [Skill] {
        let stmt = try database.prepare("""
            SELECT id, user_id, payload, state, fired_count, created_at, last_modified_at, last_fired_at
            FROM skills
            WHERE user_id = ?;
        """)
        try stmt.bind(userId, at: 1)

        var skills: [Skill] = []
        while try stmt.step() {
            if let skill = skill(from: stmt) {
                skills.append(skill)
            }
        }
        return skills
    }

    func fetchActiveSkills(userId: String) throws -> [Skill] {
        let stmt = try database.prepare("""
            SELECT id, user_id, payload, state, fired_count, created_at, last_modified_at, last_fired_at
            FROM skills
            WHERE user_id = ? AND state = 'active';
        """)
        try stmt.bind(userId, at: 1)

        var skills: [Skill] = []
        while try stmt.step() {
            if let skill = skill(from: stmt) {
                skills.append(skill)
            }
        }
        return skills
    }

    func fetchSkill(id: UUID) throws -> Skill? {
        let stmt = try database.prepare("""
            SELECT id, user_id, payload, state, fired_count, created_at, last_modified_at, last_fired_at
            FROM skills
            WHERE id = ?;
        """)
        try stmt.bind(id.uuidString, at: 1)

        guard try stmt.step() else { return nil }
        return skill(from: stmt)
    }

    func insertSkill(_ skill: Skill) throws {
        try validate(skill.payload)
        let payloadJSON = try encodedPayload(skill.payload)

        try nodeStore.inTransaction {
            let stmt = try database.prepare("""
                INSERT INTO skills (
                    id, user_id, payload, state, fired_count,
                    created_at, last_modified_at, last_fired_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """)
            try bind(skill, payloadJSON: payloadJSON, to: stmt)
            try stmt.step()
        }
    }

    func updateSkill(_ skill: Skill) throws {
        try validate(skill.payload)
        let payloadJSON = try encodedPayload(skill.payload)

        try nodeStore.inTransaction {
            let stmt = try database.prepare("""
                UPDATE skills
                SET user_id = ?,
                    payload = ?,
                    state = ?,
                    fired_count = ?,
                    created_at = ?,
                    last_modified_at = ?,
                    last_fired_at = ?
                WHERE id = ?;
            """)
            try stmt.bind(skill.userId, at: 1)
            try stmt.bind(payloadJSON, at: 2)
            try stmt.bind(skill.state.rawValue, at: 3)
            try stmt.bind(skill.firedCount, at: 4)
            try stmt.bind(skill.createdAt.timeIntervalSince1970, at: 5)
            try stmt.bind(skill.lastModifiedAt.timeIntervalSince1970, at: 6)
            try stmt.bind(skill.lastFiredAt?.timeIntervalSince1970, at: 7)
            try stmt.bind(skill.id.uuidString, at: 8)
            try stmt.step()
        }
    }

    func setSkillState(id: UUID, state: SkillState) throws {
        try nodeStore.inTransaction {
            let stmt = try database.prepare("""
                UPDATE skills
                SET state = ?,
                    last_modified_at = ?
                WHERE id = ?;
            """)
            try stmt.bind(state.rawValue, at: 1)
            try stmt.bind(Date().timeIntervalSince1970, at: 2)
            try stmt.bind(id.uuidString, at: 3)
            try stmt.step()
        }
    }

    func incrementFiredCount(id: UUID, firedAt: Date) throws {
        try nodeStore.inTransaction {
            let stmt = try database.prepare("""
                UPDATE skills
                SET fired_count = fired_count + 1,
                    last_fired_at = ?
                WHERE id = ?;
            """)
            try stmt.bind(firedAt.timeIntervalSince1970, at: 1)
            try stmt.bind(id.uuidString, at: 2)
            try stmt.step()
        }
    }

    private var database: Database {
        nodeStore.rawDatabase
    }

    private func validate(_ payload: SkillPayload) throws {
        guard payload.payloadVersion == 1 else {
            throw SkillStoreError.invalidPayloadVersion(payload.payloadVersion)
        }
        guard !payload.trigger.modes.isEmpty else {
            throw SkillStoreError.emptyModes
        }
        guard 0...100 ~= payload.trigger.priority else {
            throw SkillStoreError.priorityOutOfRange(payload.trigger.priority)
        }
        guard !payload.action.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SkillStoreError.emptyActionContent
        }
    }

    private func encodedPayload(_ payload: SkillPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SkillStoreError.payloadEncodingFailed
        }
        return json
    }

    private func bind(_ skill: Skill, payloadJSON: String, to stmt: Statement) throws {
        try stmt.bind(skill.id.uuidString, at: 1)
        try stmt.bind(skill.userId, at: 2)
        try stmt.bind(payloadJSON, at: 3)
        try stmt.bind(skill.state.rawValue, at: 4)
        try stmt.bind(skill.firedCount, at: 5)
        try stmt.bind(skill.createdAt.timeIntervalSince1970, at: 6)
        try stmt.bind(skill.lastModifiedAt.timeIntervalSince1970, at: 7)
        try stmt.bind(skill.lastFiredAt?.timeIntervalSince1970, at: 8)
    }

    private func skill(from stmt: Statement) -> Skill? {
        guard let idString = stmt.text(at: 0),
              let id = UUID(uuidString: idString) else {
            print("[SkillStore] skipping row with invalid skill id")
            return nil
        }
        guard let stateRaw = stmt.text(at: 3),
              let state = SkillState(rawValue: stateRaw) else {
            print("[SkillStore] skipping skill \(id) with invalid state")
            return nil
        }
        guard let payloadJSON = stmt.text(at: 2),
              let payloadData = payloadJSON.data(using: .utf8) else {
            print("[SkillStore] skipping skill \(id) with invalid payload text")
            return nil
        }

        do {
            let payload = try JSONDecoder().decode(SkillPayload.self, from: payloadData)
            let lastFiredAt = stmt.text(at: 7)
                .flatMap(Double.init)
                .map(Date.init(timeIntervalSince1970:))
            return Skill(
                id: id,
                userId: stmt.text(at: 1) ?? "alex",
                payload: payload,
                state: state,
                firedCount: stmt.int(at: 4),
                createdAt: Date(timeIntervalSince1970: stmt.double(at: 5)),
                lastModifiedAt: Date(timeIntervalSince1970: stmt.double(at: 6)),
                lastFiredAt: lastFiredAt
            )
        } catch {
            print("[SkillStore] skipping skill \(id) with undecodable payload: \(error)")
            return nil
        }
    }
}
