import Foundation

final class FailureSkillRepairRunStore {
    private let nodeStore: NodeStore

    init(nodeStore: NodeStore) {
        self.nodeStore = nodeStore
    }

    func insertRun(_ run: FailureSkillRepairRun) throws {
        let stmt = try database.prepare("""
            INSERT INTO failure_skill_repair_runs (
                id, candidate_id, status, bead_id, branch_name, commit_sha, pr_url,
                log_excerpt, error, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        try bind(run, to: stmt)
        try stmt.step()
    }

    func updateRun(_ run: FailureSkillRepairRun) throws {
        let stmt = try database.prepare("""
            UPDATE failure_skill_repair_runs
            SET candidate_id = ?,
                status = ?,
                bead_id = ?,
                branch_name = ?,
                commit_sha = ?,
                pr_url = ?,
                log_excerpt = ?,
                error = ?,
                created_at = ?,
                updated_at = ?
            WHERE id = ?;
        """)
        try stmt.bind(run.candidateId.uuidString, at: 1)
        try stmt.bind(run.status.rawValue, at: 2)
        try stmt.bind(run.beadId, at: 3)
        try stmt.bind(run.branchName, at: 4)
        try stmt.bind(run.commitSHA, at: 5)
        try stmt.bind(run.prURL, at: 6)
        try stmt.bind(run.logExcerpt, at: 7)
        try stmt.bind(run.error, at: 8)
        try stmt.bind(run.createdAt.timeIntervalSince1970, at: 9)
        try stmt.bind(run.updatedAt.timeIntervalSince1970, at: 10)
        try stmt.bind(run.id.uuidString, at: 11)
        try stmt.step()
    }

    func cancelActiveRun(id: UUID, updatedAt: Date = Date()) throws {
        let stmt = try database.prepare("""
            UPDATE failure_skill_repair_runs
            SET status = ?,
                updated_at = ?
            WHERE id = ?
              AND status IN ('requested', 'running');
        """)
        try stmt.bind(FailureSkillRepairRunStatus.cancelled.rawValue, at: 1)
        try stmt.bind(updatedAt.timeIntervalSince1970, at: 2)
        try stmt.bind(id.uuidString, at: 3)
        try stmt.step()
    }

    func fetchRun(id: UUID) throws -> FailureSkillRepairRun? {
        let stmt = try database.prepare("""
            SELECT id, candidate_id, status, bead_id, branch_name, commit_sha, pr_url,
                   log_excerpt, error, created_at, updated_at
            FROM failure_skill_repair_runs
            WHERE id = ?;
        """)
        try stmt.bind(id.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        return run(from: stmt)
    }

    func fetchLatestRun(candidateId: UUID) throws -> FailureSkillRepairRun? {
        let stmt = try database.prepare("""
            SELECT id, candidate_id, status, bead_id, branch_name, commit_sha, pr_url,
                   log_excerpt, error, created_at, updated_at
            FROM failure_skill_repair_runs
            WHERE candidate_id = ?
            ORDER BY updated_at DESC, created_at DESC
            LIMIT 1;
        """)
        try stmt.bind(candidateId.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        return run(from: stmt)
    }

    func fetchActiveRun(candidateId: UUID) throws -> FailureSkillRepairRun? {
        let stmt = try database.prepare("""
            SELECT id, candidate_id, status, bead_id, branch_name, commit_sha, pr_url,
                   log_excerpt, error, created_at, updated_at
            FROM failure_skill_repair_runs
            WHERE candidate_id = ?
              AND status IN ('requested', 'running')
            ORDER BY updated_at DESC, created_at DESC
            LIMIT 1;
        """)
        try stmt.bind(candidateId.uuidString, at: 1)
        guard try stmt.step() else { return nil }
        return run(from: stmt)
    }

    private var database: Database {
        nodeStore.rawDatabase
    }

    private func bind(_ run: FailureSkillRepairRun, to stmt: Statement) throws {
        try stmt.bind(run.id.uuidString, at: 1)
        try stmt.bind(run.candidateId.uuidString, at: 2)
        try stmt.bind(run.status.rawValue, at: 3)
        try stmt.bind(run.beadId?.boundedFailureRepairText(), at: 4)
        try stmt.bind(run.branchName.boundedFailureRepairText(limit: 180) ?? run.branchName, at: 5)
        try stmt.bind(run.commitSHA?.boundedFailureRepairText(limit: 80), at: 6)
        try stmt.bind(run.prURL?.boundedFailureRepairText(limit: 240), at: 7)
        try stmt.bind(run.logExcerpt?.boundedFailureRepairText(limit: 500), at: 8)
        try stmt.bind(run.error?.boundedFailureRepairText(limit: 500), at: 9)
        try stmt.bind(run.createdAt.timeIntervalSince1970, at: 10)
        try stmt.bind(run.updatedAt.timeIntervalSince1970, at: 11)
    }

    private func run(from stmt: Statement) -> FailureSkillRepairRun? {
        guard let id = stmt.text(at: 0).flatMap(UUID.init(uuidString:)),
              let candidateId = stmt.text(at: 1).flatMap(UUID.init(uuidString:)),
              let statusText = stmt.text(at: 2),
              let status = FailureSkillRepairRunStatus(rawValue: statusText),
              let branchName = stmt.text(at: 4) else {
            return nil
        }
        return FailureSkillRepairRun(
            id: id,
            candidateId: candidateId,
            status: status,
            beadId: stmt.text(at: 3),
            branchName: branchName,
            commitSHA: stmt.text(at: 5),
            prURL: stmt.text(at: 6),
            logExcerpt: stmt.text(at: 7),
            error: stmt.text(at: 8),
            createdAt: Date(timeIntervalSince1970: stmt.double(at: 9)),
            updatedAt: Date(timeIntervalSince1970: stmt.double(at: 10))
        )
    }
}
