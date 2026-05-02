import Foundation

protocol SkillStoring {
    func fetchAllSkills(userId: String) throws -> [Skill]
    func fetchActiveSkills(userId: String) throws -> [Skill]
    func fetchSkill(id: UUID) throws -> Skill?
    func loadedSkills(in conversationID: UUID) throws -> [LoadedSkill]
    func markSkillLoaded(skillID: UUID, in conversationID: UUID, at loadedAt: Date) throws -> MarkSkillLoadedResult
    func unloadAllSkills(in conversationID: UUID) throws
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

    func loadedSkills(in conversationID: UUID) throws -> [LoadedSkill] {
        let stmt = try database.prepare("""
            SELECT skill_id, name_snapshot, content_snapshot, state_at_load, loaded_at
            FROM conversation_loaded_skills
            WHERE conversation_id = ?
            ORDER BY loaded_at ASC, skill_id ASC;
        """)
        try stmt.bind(conversationID.uuidString, at: 1)

        var skills: [LoadedSkill] = []
        while try stmt.step() {
            if let skill = loadedSkill(from: stmt) {
                skills.append(skill)
            }
        }
        return skills
    }

    func markSkillLoaded(skillID: UUID, in conversationID: UUID, at loadedAt: Date) throws -> MarkSkillLoadedResult {
        var result: MarkSkillLoadedResult = .missingSkill

        try nodeStore.inTransaction {
            if let loaded = try loadedSkillRow(skillID: skillID, conversationID: conversationID) {
                result = .alreadyLoaded(loaded)
                return
            }

            guard let skill = try fetchSkill(id: skillID) else {
                result = .missingSkill
                return
            }

            guard skill.state == .active else {
                result = .unavailable(skill.state)
                return
            }

            let loaded = LoadedSkill(
                skillID: skill.id,
                nameSnapshot: skill.payload.name,
                contentSnapshot: skill.payload.action.content,
                stateAtLoad: skill.state,
                loadedAt: loadedAt
            )
            try insertLoadedSkill(loaded, conversationID: conversationID)
            try incrementFiredCountWithoutTransaction(id: skill.id, firedAt: loadedAt)
            result = .inserted(loaded)
        }

        return result
    }

    func unloadAllSkills(in conversationID: UUID) throws {
        try nodeStore.inTransaction {
            let stmt = try database.prepare("""
                DELETE FROM conversation_loaded_skills
                WHERE conversation_id = ?;
            """)
            try stmt.bind(conversationID.uuidString, at: 1)
            try stmt.step()
        }
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
            try incrementFiredCountWithoutTransaction(id: id, firedAt: firedAt)
        }
    }

    private var database: Database {
        nodeStore.rawDatabase
    }

    private func validate(_ payload: SkillPayload) throws {
        guard (1...2).contains(payload.payloadVersion) else {
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

    private func loadedSkillRow(skillID: UUID, conversationID: UUID) throws -> LoadedSkill? {
        let stmt = try database.prepare("""
            SELECT skill_id, name_snapshot, content_snapshot, state_at_load, loaded_at
            FROM conversation_loaded_skills
            WHERE conversation_id = ? AND skill_id = ?;
        """)
        try stmt.bind(conversationID.uuidString, at: 1)
        try stmt.bind(skillID.uuidString, at: 2)

        guard try stmt.step() else { return nil }
        return loadedSkill(from: stmt)
    }

    private func insertLoadedSkill(_ loaded: LoadedSkill, conversationID: UUID) throws {
        let stmt = try database.prepare("""
            INSERT INTO conversation_loaded_skills (
                conversation_id, skill_id, name_snapshot, content_snapshot, state_at_load, loaded_at
            )
            VALUES (?, ?, ?, ?, ?, ?);
        """)
        try stmt.bind(conversationID.uuidString, at: 1)
        try stmt.bind(loaded.skillID.uuidString, at: 2)
        try stmt.bind(loaded.nameSnapshot, at: 3)
        try stmt.bind(loaded.contentSnapshot, at: 4)
        try stmt.bind(loaded.stateAtLoad.rawValue, at: 5)
        try stmt.bind(loaded.loadedAt.timeIntervalSince1970, at: 6)
        try stmt.step()
    }

    private func incrementFiredCountWithoutTransaction(id: UUID, firedAt: Date) throws {
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

    private func loadedSkill(from stmt: Statement) -> LoadedSkill? {
        guard let idString = stmt.text(at: 0),
              let id = UUID(uuidString: idString) else {
            print("[SkillStore] skipping loaded skill row with invalid skill id")
            return nil
        }
        guard let stateRaw = stmt.text(at: 3),
              let state = SkillState(rawValue: stateRaw) else {
            print("[SkillStore] skipping loaded skill \(id) with invalid state")
            return nil
        }

        return LoadedSkill(
            skillID: id,
            nameSnapshot: stmt.text(at: 1) ?? "",
            contentSnapshot: stmt.text(at: 2) ?? "",
            stateAtLoad: state,
            loadedAt: Date(timeIntervalSince1970: stmt.double(at: 4))
        )
    }
}
