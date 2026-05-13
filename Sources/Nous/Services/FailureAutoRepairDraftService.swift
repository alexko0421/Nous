import Foundation

struct FailureRepairCommand: Equatable {
    let executable: String
    let arguments: [String]
    let standardInput: String?

    init(_ executable: String, _ arguments: [String] = [], standardInput: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.standardInput = standardInput
    }
}

protocol FailureRepairCommandRunning {
    func run(_ command: FailureRepairCommand) throws -> String
}

private final class FailureRepairOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

struct ProcessFailureRepairCommandRunner: FailureRepairCommandRunning {
    let workingDirectoryURL: URL

    func run(_ command: FailureRepairCommand) throws -> String {
        let process = Process()
        let resolved = resolvedExecutable(command.executable)
        process.executableURL = resolved.url
        process.arguments = resolved.arguments + command.arguments
        process.currentDirectoryURL = workingDirectoryURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutBuffer = FailureRepairOutputBuffer()
        let stderrBuffer = FailureRepairOutputBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutBuffer.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrBuffer.append(handle.availableData)
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }
        if let standardInput = command.standardInput {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data(standardInput.utf8))
            input.fileHandleForWriting.closeFile()
        } else {
            try process.run()
        }
        process.waitUntilExit()

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        let remainingStdout = stdout.fileHandleForReading.readDataToEndOfFile()
        let remainingStderr = stderr.fileHandleForReading.readDataToEndOfFile()
        stdoutBuffer.append(remainingStdout)
        stderrBuffer.append(remainingStderr)
        let output = stdoutBuffer.string()
        let errorOutput = stderrBuffer.string()
        guard process.terminationStatus == 0 else {
            throw FailureAutoRepairDraftServiceError.commandFailed(
                (output + "\n" + errorOutput).boundedFailureRepairText(limit: 500) ?? command.executable
            )
        }
        return output
    }

    private func resolvedExecutable(_ name: String) -> (url: URL, arguments: [String]) {
        if name.hasPrefix("/") {
            return (URL(fileURLWithPath: name), [])
        }
        if name.contains("/") {
            return (workingDirectoryURL.appendingPathComponent(name), [])
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), [name])
    }
}

enum FailureAutoRepairDraftServiceError: LocalizedError, Equatable {
    case dirtyWorktree
    case candidateRequiresApproval
    case unsupportedRepairKind
    case incompleteChecklist
    case repairAlreadyRunning
    case repairDraftAlreadyOpened
    case commandFailed(String)
    case disallowedRepairDiff([String])
    case missingBeadId
    case missingCandidate
    case noRepairDiff
    case invalidChecklist

    var errorDescription: String? {
        switch self {
        case .dirtyWorktree:
            return "Git worktree is dirty."
        case .candidateRequiresApproval:
            return "Failure candidate must be approved first."
        case .unsupportedRepairKind:
            return "This repair kind is not supported by auto repair drafts."
        case .incompleteChecklist:
            return "Skillify checklist is incomplete."
        case .repairAlreadyRunning:
            return "A repair draft run is already active for this candidate."
        case .repairDraftAlreadyOpened:
            return "A draft repair PR is already open for this candidate."
        case .commandFailed(let message):
            return "Repair command failed: \(message)"
        case .disallowedRepairDiff(let paths):
            return "Repair touched disallowed paths: \(paths.prefix(4).joined(separator: ", "))"
        case .missingBeadId:
            return "Bead creation did not return an id."
        case .missingCandidate:
            return "Failure candidate could not be found."
        case .noRepairDiff:
            return "Codex repair produced no tracked diff."
        case .invalidChecklist:
            return "Skillify checklist has invalid test or smoke references."
        }
    }
}

final class FailureAutoRepairDraftService {
    private let repositoryURL: URL
    private let commandRunner: any FailureRepairCommandRunning

    init(
        repositoryURL: URL = FailureAutoRepairDraftService.defaultRepositoryURL(),
        commandRunner: (any FailureRepairCommandRunning)? = nil
    ) {
        self.repositoryURL = repositoryURL
        self.commandRunner = commandRunner ?? ProcessFailureRepairCommandRunner(workingDirectoryURL: repositoryURL)
    }

    func preflight(candidate: FailureSkillCandidate, latestRun: FailureSkillRepairRun?) throws {
        if let latestRun, latestRun.status.isActive {
            throw FailureAutoRepairDraftServiceError.repairAlreadyRunning
        }
        if let latestRun, latestRun.status == .draftPROpened {
            throw FailureAutoRepairDraftServiceError.repairDraftAlreadyOpened
        }
        guard try commandRunner.run(FailureRepairCommand("git", ["status", "--porcelain", "--untracked-files=all"]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
            throw FailureAutoRepairDraftServiceError.dirtyWorktree
        }
        guard candidate.status == .approved else {
            throw FailureAutoRepairDraftServiceError.candidateRequiresApproval
        }
        guard candidate.repairKind != .observeOnly else {
            throw FailureAutoRepairDraftServiceError.unsupportedRepairKind
        }
        let evaluation = SkillifyChecklistEvaluator().evaluate(candidate)
        guard evaluation.missingItems.isEmpty else {
            throw FailureAutoRepairDraftServiceError.incompleteChecklist
        }
        guard Self.checklistAllowsRepairDraft(evaluation, repairKind: candidate.repairKind) else {
            throw FailureAutoRepairDraftServiceError.invalidChecklist
        }
    }

    static func checklistAllowsRepairDraft(
        _ evaluation: SkillifyChecklistEvaluation,
        repairKind: FailureRepairKind
    ) -> Bool {
        guard evaluation.missingItems.isEmpty else { return false }
        guard let blockingReason = evaluation.blockingReason else { return true }
        switch blockingReason {
        case .deterministicFixCannotActivateSkill:
            return repairKind == .deterministicFix
        case .incompleteChecklist:
            return repairKind == .regressionOnly
        case .missingSkillPayload,
             .invalidSkillPayload,
             .invalidRegressionTestReference,
             .invalidResolverTestReference,
             .invalidSmokeTestCommand:
            return false
        }
    }

    func createDraftPR(
        for candidate: FailureSkillCandidate,
        runStore: FailureSkillRepairRunStore,
        candidateStore: FailureSkillCandidateStore,
        now: Date = Date()
    ) throws -> FailureSkillRepairRun {
        guard let currentCandidate = try candidateStore.fetchCandidate(id: candidate.id) else {
            throw FailureAutoRepairDraftServiceError.missingCandidate
        }
        let latestRun = try runStore.fetchLatestRun(candidateId: currentCandidate.id)
        try preflight(candidate: currentCandidate, latestRun: latestRun)

        var run = FailureSkillRepairRun(
            id: UUID(),
            candidateId: currentCandidate.id,
            status: .requested,
            beadId: nil,
            branchName: branchName(for: currentCandidate),
            commitSHA: nil,
            prURL: nil,
            logExcerpt: nil,
            error: nil,
            createdAt: now,
            updatedAt: now
        )
        try runStore.insertRun(run)

        do {
            let beadOutput = try commandRunner.run(FailureRepairCommand(
                "scripts/beads_agent_workflow.sh",
                [
                    "create",
                    "AutoRepair for \(currentCandidate.signature.displayName)",
                    "Repair approved failure candidate \(currentCandidate.id.uuidString).",
                    "1"
                ]
            ))
            guard let beadId = Self.parseBeadId(from: beadOutput) else {
                throw FailureAutoRepairDraftServiceError.missingBeadId
            }
            run.status = .running
            run.beadId = beadId
            run.updatedAt = Date()
            try runStore.updateRun(run)

            _ = try commandRunner.run(FailureRepairCommand("git", ["fetch", "origin", "main"]))
            _ = try commandRunner.run(FailureRepairCommand("git", ["switch", "-C", run.branchName, "origin/main"]))
            let codexOutput = try commandRunner.run(FailureRepairCommand(
                "codex",
                ["exec", "--cd", repositoryURL.path, "--sandbox", "workspace-write", "--ask-for-approval", "never"],
                standardInput: repairBrief(for: currentCandidate, beadId: beadId)
            ))
            run.logExcerpt = codexOutput.boundedFailureRepairText(limit: 500)
            try runStore.updateRun(run)

            _ = try commandRunner.run(FailureRepairCommand("xcodegen", ["generate"]))
            if let smoke = currentCandidate.checklist.smokeTestCommand {
                _ = try commandRunner.run(FailureRepairCommand("/bin/zsh", ["-lc", smoke]))
            }
            _ = try commandRunner.run(FailureRepairCommand("git", ["diff", "--check"]))
            _ = try commandRunner.run(FailureRepairCommand("scripts/agentic_workflow_check.sh", ["--bead", beadId]))
            let repairStatus = try commandRunner.run(FailureRepairCommand(
                "git",
                ["status", "--porcelain", "--untracked-files=all"]
            ))
            guard !repairStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FailureAutoRepairDraftServiceError.noRepairDiff
            }
            try validateRepairDiffScope(repairStatus)
            _ = try commandRunner.run(FailureRepairCommand("git", ["add", "-A"]))
            _ = try commandRunner.run(FailureRepairCommand("git", ["diff", "--cached", "--check"]))
            _ = try commandRunner.run(FailureRepairCommand(
                "git",
                ["commit", "-m", "Repair failure skill candidate \(currentCandidate.signature.rawValue)"]
            ))
            run.commitSHA = try commandRunner.run(FailureRepairCommand("git", ["rev-parse", "HEAD"]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try commandRunner.run(FailureRepairCommand("git", ["push", "-u", "origin", run.branchName]))
            run.prURL = try commandRunner.run(FailureRepairCommand(
                "gh",
                [
                    "pr", "create",
                    "--draft",
                    "--base", "main",
                    "--head", run.branchName,
                    "--title", "[codex] Repair \(currentCandidate.signature.rawValue) failure candidate",
                    "--body-file", "-"
                ],
                standardInput: prBody(for: currentCandidate, beadId: beadId)
            ))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try? commandRunner.run(FailureRepairCommand(
                "scripts/beads_agent_workflow.sh",
                ["finish", beadId, "AutoRepairDraft opened draft PR \(run.prURL ?? "") after verification."]
            ))
            run.status = .draftPROpened
            run.updatedAt = Date()
            try runStore.updateRun(run)
            return run
        } catch {
            run.status = .failed
            run.error = error.localizedDescription.boundedFailureRepairText(limit: 500)
            run.updatedAt = Date()
            if let beadId = run.beadId {
                _ = try? commandRunner.run(FailureRepairCommand(
                    "scripts/beads_agent_workflow.sh",
                    [
                        "finish",
                        beadId,
                        "AutoRepairDraft failed: \(run.error ?? error.localizedDescription)"
                    ]
                ))
            }
            try? runStore.updateRun(run)
            throw error
        }
    }

    private func branchName(for candidate: FailureSkillCandidate) -> String {
        "codex/failure-repair-\(candidate.signature.rawValue)-\(String(candidate.id.uuidString.prefix(8)))"
    }

    private func repairBrief(for candidate: FailureSkillCandidate, beadId: String) -> String {
        """
        Implement a minimal repair for approved FailureSkillCandidate \(candidate.id.uuidString).
        Bead: \(beadId)
        Signature: \(candidate.signature.rawValue)
        Repair kind: \(candidate.repairKind.rawValue)
        Root cause: \(candidate.checklist.rootCause ?? "")
        Trigger: \(candidate.checklist.trigger ?? "")
        Use when: \(candidate.checklist.useWhen ?? "")
        Anti-pattern: \(candidate.checklist.antiPatternExample ?? "")
        Regression test: \(candidate.checklist.regressionTestReference ?? "")
        Resolver test: \(candidate.checklist.resolverTestReference ?? "")
        Smoke command: \(candidate.checklist.smokeTestCommand ?? "")
        Evidence:
        \(evidenceBrief(for: candidate))
        Allowed files:
        \(allowedFileGuidance(for: candidate))

        Requirements:
        - Use TDD: add or update the focused failing test first.
        - Keep the diff minimal and scoped to this failure.
        - Do not modify Sources/Nous/Resources/anchor.md.
        - Run the smoke command before final response.
        """
    }

    private func evidenceBrief(for candidate: FailureSkillCandidate) -> String {
        guard !candidate.evidence.isEmpty else {
            return "- No evidence snippets were recorded; rely on candidate metadata and tests."
        }
        return candidate.evidence.prefix(8).map { evidence in
            let snippet = evidence.snippet?.replacingOccurrences(of: "\n", with: " ") ?? ""
            return "- \(evidence.source.rawValue) id=\(evidence.id) snippet=\(snippet)"
        }
        .joined(separator: "\n")
    }

    private func allowedFileGuidance(for candidate: FailureSkillCandidate) -> String {
        let codeReference = candidate.checklist.codeReference ?? "No specific code reference supplied."
        return """
        - Prefer the smallest relevant edits under Sources/Nous/ and Tests/NousTests/.
        - Project generation may update Nous.xcodeproj/project.pbxproj after xcodegen generate.
        - Checklist code reference: \(codeReference)
        - Never modify Sources/Nous/Resources/anchor.md or store hidden prompt/transcript dumps.
        """
    }

    private func validateRepairDiffScope(_ porcelainStatus: String) throws {
        let changedPaths = Self.changedPaths(fromPorcelainStatus: porcelainStatus)
        let disallowed = changedPaths.filter { !Self.isAllowedRepairPath($0) }
        guard disallowed.isEmpty else {
            throw FailureAutoRepairDraftServiceError.disallowedRepairDiff(disallowed)
        }
    }

    private static func changedPaths(fromPorcelainStatus status: String) -> [String] {
        status
            .split(separator: "\n")
            .flatMap { line -> [String] in
                guard line.count > 3 else { return [] }
                let rawPath = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rawPath.contains(" -> ") {
                    return rawPath
                        .components(separatedBy: " -> ")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
                return rawPath.isEmpty ? [] : [rawPath]
            }
    }

    private static func isAllowedRepairPath(_ path: String) -> Bool {
        guard path != "Sources/Nous/Resources/anchor.md" else { return false }
        return path.hasPrefix("Sources/Nous/")
            || path.hasPrefix("Tests/NousTests/")
            || path == "Nous.xcodeproj/project.pbxproj"
    }

    private func prBody(for candidate: FailureSkillCandidate, beadId: String) -> String {
        """
        ## Summary

        AutoRepairDraft for FailureSkillCandidate \(candidate.id.uuidString).

        - Signature: \(candidate.signature.displayName)
        - Repair kind: \(candidate.repairKind.displayName)
        - Bead: \(beadId)

        ## Validation

        - xcodegen generate
        - \(candidate.checklist.smokeTestCommand ?? "smoke command unavailable")
        - git diff --check
        - scripts/agentic_workflow_check.sh --bead \(beadId)
        """
    }

    private static func parseBeadId(from output: String) -> String? {
        if let data = output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = object["id"] as? String {
            return id
        }
        return output
            .split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == ":" || $0 == "," })
            .map(String.init)
            .first { $0.hasPrefix("new-york-") }
    }

    static func defaultRepositoryURL() -> URL {
        let fileManager = FileManager.default
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("project.yml").path),
               fileManager.fileExists(atPath: candidate.appendingPathComponent("scripts/beads_agent_workflow.sh").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: fileManager.currentDirectoryPath)
    }
}
