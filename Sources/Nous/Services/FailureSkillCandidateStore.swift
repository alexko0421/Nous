import Foundation

enum FailureSkillCandidateStoreError: LocalizedError, Equatable {
    case encodingFailed
    case missingCandidate
    case activationRequiresApproval
    case activationNotAllowed(SkillifyChecklistBlockingReason?)
    case alreadyActivated

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failure skill candidate could not be encoded."
        case .missingCandidate:
            return "Failure skill candidate was not found."
        case .activationRequiresApproval:
            return "Failure skill candidate must be approved before activation."
        case .activationNotAllowed(let reason):
            return "Failure skill candidate cannot be activated: \(reason?.rawValue ?? "unknown")."
        case .alreadyActivated:
            return "Failure skill candidate is already activated."
        }
    }
}

final class FailureSkillCandidateStore {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func upsertCandidate(_ candidate: FailureSkillCandidate) throws {
        try upsertCandidate(candidate, applyingAutoTriage: true, promotingRecurringPatterns: true)
    }

    func runAutoTriage(userId: String, limit: Int) throws -> Int {
        let candidates = try fetchRecentCandidates(userId: userId, limit: limit)
            .filter { $0.sourceKind != .recurringPattern }
        var updatedCount = 0
        for candidate in candidates {
            let triaged = FailureSkillTriageService().triage(candidate)
            guard triaged != candidate else { continue }
            try updateCandidate(triaged)
            updatedCount += 1
        }
        return updatedCount
    }

    @discardableResult
    func runRecurringPatternPromotion(
        userId: String,
        limit: Int,
        threshold: Int = 2,
        now: Date = Date()
    ) throws -> Int {
        guard limit > 0, threshold > 1 else { return 0 }
        let candidates = try fetchRecentCandidates(userId: userId, limit: limit)
        let existingPatternsBySourceId = Dictionary(
            uniqueKeysWithValues: candidates
                .filter { $0.sourceKind == .recurringPattern }
                .map { ($0.sourceId, $0) }
        )
        let grouped = Dictionary(grouping: candidates.filter {
            $0.sourceKind != .recurringPattern
                && $0.status != .dismissed
                && $0.status != .activated
        }) { candidate in
            RecurringPatternKey(signature: candidate.signature, repairKind: candidate.repairKind)
        }

        var promotedCount = 0
        for existing in existingPatternsBySourceId.values {
            guard existing.status != .dismissed,
                  existing.status != .activated else {
                continue
            }
            let key = RecurringPatternKey(signature: existing.signature, repairKind: existing.repairKind)
            let rows = sortedRows(grouped[key] ?? [])
            guard rows.count < threshold else { continue }

            let staleEvidence = evidenceRows(from: rows)
            let staleChecklist = SkillifyChecklist(
                rootCause: "\(key.signature.displayName) no longer meets the recurring threshold (\(rows.count)/\(threshold) active signals)."
            )
            guard existing.status != .proposed
                    || existing.evidence != staleEvidence
                    || existing.proposedSkillPayload != nil
                    || existing.checklist != staleChecklist
                    || existing.activatedSkillId != nil else {
                continue
            }

            var stale = existing
            stale.status = .proposed
            stale.evidence = staleEvidence
            stale.proposedSkillPayload = nil
            stale.checklist = staleChecklist
            stale.updatedAt = now
            stale.activatedSkillId = nil
            try updateCandidate(stale)
            promotedCount += 1
        }

        for (key, rows) in grouped where rows.count >= threshold {
            let sourceId = key.sourceId
            if let existing = existingPatternsBySourceId[sourceId],
               existing.status == .dismissed || existing.status == .activated {
                continue
            }

            let existing = existingPatternsBySourceId[sourceId]
            let evidence = evidenceRows(from: sortedRows(rows))
            let candidate = FailureSkillCandidate(
                id: existing?.id ?? UUID(),
                userId: userId,
                sourceKind: .recurringPattern,
                sourceId: sourceId,
                turnId: nil,
                conversationId: nil,
                assistantMessageId: nil,
                signature: key.signature,
                repairKind: key.repairKind,
                status: existing?.status ?? .proposed,
                evidence: evidence,
                proposedSkillPayload: existing?.proposedSkillPayload,
                checklist: existing?.checklist ?? SkillifyChecklist(
                    rootCause: "\(key.signature.displayName) recurred across \(rows.count) recent failure candidates."
                ),
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                activatedSkillId: existing?.activatedSkillId
            )
            try upsertCandidate(candidate, applyingAutoTriage: true, promotingRecurringPatterns: false)
            promotedCount += 1
        }
        return promotedCount
    }

    #if DEBUG
    func insertCandidateWithoutAutoTriageForTests(_ candidate: FailureSkillCandidate) throws {
        try upsertCandidate(candidate, applyingAutoTriage: false, promotingRecurringPatterns: false)
    }
    #endif

    private func upsertCandidate(
        _ candidate: FailureSkillCandidate,
        applyingAutoTriage: Bool,
        promotingRecurringPatterns: Bool
    ) throws {
        let candidate = applyingAutoTriage
            ? FailureSkillTriageService().triage(candidate)
            : candidate
        let encoded = try encodedColumns(for: candidate)
        try nodeStore.inTransaction {
            let stmt = try database.prepare("""
                INSERT INTO failure_skill_candidates (
                    id, user_id, source_kind, source_id, turn_id, conversation_id, assistant_message_id,
                    signature, repair_kind, status, evidence_json, proposed_skill_payload_json,
                    checklist_json, created_at, updated_at, activated_skill_id
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_kind, source_id, signature) DO UPDATE SET
                    turn_id = excluded.turn_id,
                    conversation_id = excluded.conversation_id,
                    assistant_message_id = excluded.assistant_message_id,
                    repair_kind = CASE
                        WHEN failure_skill_candidates.status = 'approved'
                             AND excluded.status = 'proposed'
                             AND failure_skill_candidates.repair_kind = excluded.repair_kind
                        THEN failure_skill_candidates.repair_kind
                        ELSE excluded.repair_kind
                    END,
                    status = CASE
                        WHEN failure_skill_candidates.status = 'approved'
                             AND excluded.status = 'proposed'
                             AND failure_skill_candidates.repair_kind = excluded.repair_kind
                        THEN failure_skill_candidates.status
                        ELSE excluded.status
                    END,
                    evidence_json = excluded.evidence_json,
                    proposed_skill_payload_json = CASE
                        WHEN failure_skill_candidates.status = 'approved'
                             AND excluded.status = 'proposed'
                             AND failure_skill_candidates.repair_kind = excluded.repair_kind
                        THEN failure_skill_candidates.proposed_skill_payload_json
                        ELSE excluded.proposed_skill_payload_json
                    END,
                    checklist_json = CASE
                        WHEN failure_skill_candidates.status = 'approved'
                             AND excluded.status = 'proposed'
                             AND failure_skill_candidates.repair_kind = excluded.repair_kind
                        THEN failure_skill_candidates.checklist_json
                        ELSE excluded.checklist_json
                    END,
                    updated_at = excluded.updated_at,
                    activated_skill_id = CASE
                        WHEN failure_skill_candidates.status = 'approved'
                             AND excluded.status = 'proposed'
                             AND failure_skill_candidates.repair_kind = excluded.repair_kind
                        THEN failure_skill_candidates.activated_skill_id
                        ELSE excluded.activated_skill_id
                    END
                WHERE failure_skill_candidates.status NOT IN ('dismissed', 'activated');
            """)
            try bind(candidate, encoded: encoded, to: stmt)
            try stmt.step()
        }
        if promotingRecurringPatterns, candidate.sourceKind != .recurringPattern {
            _ = try runRecurringPatternPromotion(userId: candidate.userId, limit: 50, threshold: 2)
        }
    }

    func updateCandidate(_ candidate: FailureSkillCandidate) throws {
        let encoded = try encodedColumns(for: candidate)
        try nodeStore.inTransaction {
            try updateCandidateWithoutTransaction(candidate, encoded: encoded)
        }
    }

    func fetchCandidate(id: UUID) throws -> FailureSkillCandidate? {
        try fetchCandidateWithoutTransaction(id: id)
    }

    private func fetchCandidateWithoutTransaction(id: UUID) throws -> FailureSkillCandidate? {
        let stmt = try database.prepare("""
            SELECT id, user_id, source_kind, source_id, turn_id, conversation_id, assistant_message_id,
                   signature, repair_kind, status, evidence_json, proposed_skill_payload_json,
                   checklist_json, created_at, updated_at, activated_skill_id
            FROM failure_skill_candidates
            WHERE id = ?;
        """)
        try stmt.bind(id.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        return candidate(from: stmt)
    }

    func fetchRecentCandidates(userId: String, limit: Int) throws -> [FailureSkillCandidate] {
        guard limit > 0 else { return [] }
        let stmt = try database.prepare("""
            SELECT id, user_id, source_kind, source_id, turn_id, conversation_id, assistant_message_id,
                   signature, repair_kind, status, evidence_json, proposed_skill_payload_json,
                   checklist_json, created_at, updated_at, activated_skill_id
            FROM failure_skill_candidates
            WHERE user_id = ?
            ORDER BY updated_at DESC, created_at DESC
            LIMIT ?;
        """)
        try stmt.bind(userId, at: 1)
        try stmt.bind(limit, at: 2)

        var rows: [FailureSkillCandidate] = []
        while try stmt.step() {
            if let candidate = candidate(from: stmt) {
                rows.append(candidate)
            }
        }
        return rows
    }

    func setStatus(id: UUID, status: FailureSkillStatus, updatedAt: Date = Date()) throws {
        let previous = try fetchCandidate(id: id)
        try nodeStore.inTransaction {
            let stmt = try database.prepare("""
                UPDATE failure_skill_candidates
                SET status = ?, updated_at = ?
                WHERE id = ?;
            """)
            try stmt.bind(status.rawValue, at: 1)
            try stmt.bind(updatedAt.timeIntervalSince1970, at: 2)
            try stmt.bind(id.uuidString, at: 3)
            try stmt.step()
        }
        if status == .dismissed,
           let previous,
           previous.sourceKind != .recurringPattern,
           previous.status != .dismissed,
           previous.status != .activated {
            _ = try runRecurringPatternPromotion(
                userId: previous.userId,
                limit: 50,
                threshold: 2,
                now: updatedAt
            )
        }
    }

    func dismissCandidates(
        sourceKind: FailureSkillSourceKind,
        sourceId: String,
        updatedAt: Date = Date()
    ) throws {
        var affectedUserIds: Set<String> = []
        try nodeStore.inTransaction {
            let userStmt = try database.prepare("""
                SELECT DISTINCT user_id
                FROM failure_skill_candidates
                WHERE source_kind = ?
                  AND source_id = ?
                  AND status NOT IN ('dismissed', 'activated');
            """)
            try userStmt.bind(sourceKind.rawValue, at: 1)
            try userStmt.bind(sourceId, at: 2)
            while try userStmt.step() {
                if let userId = userStmt.text(at: 0) {
                    affectedUserIds.insert(userId)
                }
            }

            let stmt = try database.prepare("""
                UPDATE failure_skill_candidates
                SET status = ?, updated_at = ?
                WHERE source_kind = ?
                  AND source_id = ?
                  AND status NOT IN ('dismissed', 'activated');
            """)
            try stmt.bind(FailureSkillStatus.dismissed.rawValue, at: 1)
            try stmt.bind(updatedAt.timeIntervalSince1970, at: 2)
            try stmt.bind(sourceKind.rawValue, at: 3)
            try stmt.bind(sourceId, at: 4)
            try stmt.step()
        }

        for userId in affectedUserIds {
            _ = try runRecurringPatternPromotion(
                userId: userId,
                limit: 50,
                threshold: 2,
                now: updatedAt
            )
        }
    }

    @discardableResult
    func activateCandidate(
        id: UUID,
        skillStore: SkillStore,
        now: Date = Date()
    ) throws -> Skill {
        var activatedSkill: Skill?
        try nodeStore.inTransaction {
            guard var candidate = try fetchCandidateWithoutTransaction(id: id) else {
                throw FailureSkillCandidateStoreError.missingCandidate
            }
            guard candidate.status != .activated, candidate.activatedSkillId == nil else {
                throw FailureSkillCandidateStoreError.alreadyActivated
            }
            guard candidate.status == .approved else {
                throw FailureSkillCandidateStoreError.activationRequiresApproval
            }
            let evaluation = SkillifyChecklistEvaluator().evaluate(candidate)
            guard evaluation.canActivate else {
                throw FailureSkillCandidateStoreError.activationNotAllowed(evaluation.blockingReason)
            }
            guard let payload = candidate.proposedSkillPayload else {
                throw FailureSkillCandidateStoreError.activationNotAllowed(.missingSkillPayload)
            }

            let skill = Skill(
                id: UUID(),
                userId: candidate.userId,
                payload: payload,
                state: .active,
                firedCount: 0,
                createdAt: now,
                lastModifiedAt: now,
                lastFiredAt: nil
            )
            candidate.status = .activated
            candidate.activatedSkillId = skill.id
            candidate.updatedAt = now
            let encoded = try encodedColumns(for: candidate)
            try skillStore.insertSkillInExistingTransaction(skill, nodeStore: nodeStore)
            try updateCandidateWithoutTransaction(candidate, encoded: encoded)
            activatedSkill = skill
        }
        guard let activatedSkill else {
            throw FailureSkillCandidateStoreError.missingCandidate
        }
        return activatedSkill
    }

    private var database: Database {
        nodeStore.rawDatabase
    }

    private struct EncodedColumns {
        let evidenceJSON: String
        let proposedPayloadJSON: String?
        let checklistJSON: String
    }

    private struct RecurringPatternKey: Hashable {
        let signature: FailureSignature
        let repairKind: FailureRepairKind

        var sourceId: String {
            "\(signature.rawValue):\(repairKind.rawValue)"
        }
    }

    private func sortedRows(_ rows: [FailureSkillCandidate]) -> [FailureSkillCandidate] {
        rows.sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func evidenceRows(from rows: [FailureSkillCandidate]) -> [FailureSkillEvidence] {
        rows.prefix(6).map { candidate in
            FailureSkillEvidence(
                source: .failureSkillCandidate,
                id: candidate.id.uuidString,
                label: "\(candidate.sourceKind.rawValue):\(candidate.sourceId)"
            )
        }
    }

    private func encodedColumns(for candidate: FailureSkillCandidate) throws -> EncodedColumns {
        let encoder = JSONEncoder()
        guard let evidenceJSON = String(data: try encoder.encode(candidate.evidence), encoding: .utf8),
              let checklistJSON = String(data: try encoder.encode(candidate.checklist), encoding: .utf8) else {
            throw FailureSkillCandidateStoreError.encodingFailed
        }
        let payloadJSON: String?
        if let payload = candidate.proposedSkillPayload {
            guard let encoded = String(data: try encoder.encode(payload), encoding: .utf8) else {
                throw FailureSkillCandidateStoreError.encodingFailed
            }
            payloadJSON = encoded
        } else {
            payloadJSON = nil
        }
        return EncodedColumns(
            evidenceJSON: evidenceJSON,
            proposedPayloadJSON: payloadJSON,
            checklistJSON: checklistJSON
        )
    }

    private func bind(
        _ candidate: FailureSkillCandidate,
        encoded: EncodedColumns,
        to stmt: Statement
    ) throws {
        try stmt.bind(candidate.id.uuidString, at: 1)
        try stmt.bind(candidate.userId, at: 2)
        try stmt.bind(candidate.sourceKind.rawValue, at: 3)
        try stmt.bind(candidate.sourceId, at: 4)
        try stmt.bind(candidate.turnId?.uuidString, at: 5)
        try stmt.bind(candidate.conversationId?.uuidString, at: 6)
        try stmt.bind(candidate.assistantMessageId?.uuidString, at: 7)
        try stmt.bind(candidate.signature.rawValue, at: 8)
        try stmt.bind(candidate.repairKind.rawValue, at: 9)
        try stmt.bind(candidate.status.rawValue, at: 10)
        try stmt.bind(encoded.evidenceJSON, at: 11)
        try stmt.bind(encoded.proposedPayloadJSON, at: 12)
        try stmt.bind(encoded.checklistJSON, at: 13)
        try stmt.bind(candidate.createdAt.timeIntervalSince1970, at: 14)
        try stmt.bind(candidate.updatedAt.timeIntervalSince1970, at: 15)
        try stmt.bind(candidate.activatedSkillId?.uuidString, at: 16)
    }

    private func updateCandidateWithoutTransaction(
        _ candidate: FailureSkillCandidate,
        encoded: EncodedColumns
    ) throws {
        let stmt = try database.prepare("""
            UPDATE failure_skill_candidates
            SET user_id = ?,
                source_kind = ?,
                source_id = ?,
                turn_id = ?,
                conversation_id = ?,
                assistant_message_id = ?,
                signature = ?,
                repair_kind = ?,
                status = ?,
                evidence_json = ?,
                proposed_skill_payload_json = ?,
                checklist_json = ?,
                created_at = ?,
                updated_at = ?,
                activated_skill_id = ?
            WHERE id = ?;
        """)
        try stmt.bind(candidate.userId, at: 1)
        try stmt.bind(candidate.sourceKind.rawValue, at: 2)
        try stmt.bind(candidate.sourceId, at: 3)
        try stmt.bind(candidate.turnId?.uuidString, at: 4)
        try stmt.bind(candidate.conversationId?.uuidString, at: 5)
        try stmt.bind(candidate.assistantMessageId?.uuidString, at: 6)
        try stmt.bind(candidate.signature.rawValue, at: 7)
        try stmt.bind(candidate.repairKind.rawValue, at: 8)
        try stmt.bind(candidate.status.rawValue, at: 9)
        try stmt.bind(encoded.evidenceJSON, at: 10)
        try stmt.bind(encoded.proposedPayloadJSON, at: 11)
        try stmt.bind(encoded.checklistJSON, at: 12)
        try stmt.bind(candidate.createdAt.timeIntervalSince1970, at: 13)
        try stmt.bind(candidate.updatedAt.timeIntervalSince1970, at: 14)
        try stmt.bind(candidate.activatedSkillId?.uuidString, at: 15)
        try stmt.bind(candidate.id.uuidString, at: 16)
        try stmt.step()
    }

    private func candidate(from stmt: Statement) -> FailureSkillCandidate? {
        guard let id = stmt.text(at: 0).flatMap(UUID.init(uuidString:)),
              let userId = stmt.text(at: 1),
              let sourceKindText = stmt.text(at: 2),
              let sourceKind = FailureSkillSourceKind(rawValue: sourceKindText),
              let sourceId = stmt.text(at: 3),
              let signatureText = stmt.text(at: 7),
              let signature = FailureSignature(rawValue: signatureText),
              let repairKindText = stmt.text(at: 8),
              let repairKind = FailureRepairKind(rawValue: repairKindText),
              let statusText = stmt.text(at: 9),
              let status = FailureSkillStatus(rawValue: statusText),
              let evidenceText = stmt.text(at: 10),
              let evidenceData = evidenceText.data(using: .utf8),
              let checklistText = stmt.text(at: 12),
              let checklistData = checklistText.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        guard let evidence = try? decoder.decode([FailureSkillEvidence].self, from: evidenceData),
              let checklist = try? decoder.decode(SkillifyChecklist.self, from: checklistData) else {
            return nil
        }

        let payload: SkillPayload?
        if let payloadText = stmt.text(at: 11),
           let payloadData = payloadText.data(using: .utf8) {
            payload = try? decoder.decode(SkillPayload.self, from: payloadData)
        } else {
            payload = nil
        }

        return FailureSkillCandidate(
            id: id,
            userId: userId,
            sourceKind: sourceKind,
            sourceId: sourceId,
            turnId: stmt.text(at: 4).flatMap(UUID.init(uuidString:)),
            conversationId: stmt.text(at: 5).flatMap(UUID.init(uuidString:)),
            assistantMessageId: stmt.text(at: 6).flatMap(UUID.init(uuidString:)),
            signature: signature,
            repairKind: repairKind,
            status: status,
            evidence: evidence,
            proposedSkillPayload: payload,
            checklist: checklist,
            createdAt: Date(timeIntervalSince1970: stmt.double(at: 13)),
            updatedAt: Date(timeIntervalSince1970: stmt.double(at: 14)),
            activatedSkillId: stmt.text(at: 15).flatMap(UUID.init(uuidString:))
        )
    }
}
