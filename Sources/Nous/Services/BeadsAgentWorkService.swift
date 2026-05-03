import Foundation

protocol BeadsCommandRunning {
    func run(_ arguments: [String]) throws -> String
}

struct ProcessBeadsCommandRunner: BeadsCommandRunning {
    var workingDirectoryURL: URL?

    init(workingDirectoryURL: URL? = ProcessBeadsCommandRunner.defaultWorkingDirectoryURL()) {
        self.workingDirectoryURL = workingDirectoryURL
    }

    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let executable = resolvedExecutable()
        process.executableURL = executable.url
        process.arguments = executable.argumentsPrefix + arguments
        process.currentDirectoryURL = workingDirectoryURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw BeadsAgentWorkServiceError.commandLaunchFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw BeadsAgentWorkServiceError.commandFailed(
                arguments: arguments,
                status: Int(process.terminationStatus),
                stderr: errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return output
    }

    private func resolvedExecutable() -> (url: URL, argumentsPrefix: [String]) {
        let fileManager = FileManager.default
        for path in ["/opt/homebrew/bin/bd", "/usr/local/bin/bd"] {
            if fileManager.isExecutableFile(atPath: path) {
                return (URL(fileURLWithPath: path), [])
            }
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["bd"])
    }

    private static func defaultWorkingDirectoryURL() -> URL? {
        let sourceURL = URL(fileURLWithPath: #filePath)
        var candidate = sourceURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        while candidate.path != "/" {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent(".beads/redirect").path) ||
                fileManager.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        return URL(fileURLWithPath: fileManager.currentDirectoryPath)
    }
}

enum BeadsAgentWorkServiceError: LocalizedError, Equatable {
    case commandLaunchFailed(String)
    case commandFailed(arguments: [String], status: Int, stderr: String)
    case invalidJSON(command: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .commandLaunchFailed(let message):
            return "Could not launch bd: \(message)"
        case .commandFailed(let arguments, let status, let stderr):
            let command = "bd " + arguments.joined(separator: " ")
            if stderr.isEmpty {
                return "\(command) exited with status \(status)."
            }
            return "\(command) exited with status \(status): \(stderr)"
        case .invalidJSON(let command, let underlying):
            return "\(command) returned JSON Nous could not read: \(underlying)"
        }
    }
}

final class BeadsAgentWorkService {
    private let commandRunner: any BeadsCommandRunning
    private let harnessLoader: any HarnessHealthLoading
    private let runtimeHarnessLoader: any RuntimeHarnessLoading
    private let recentClosedLimit: Int

    init(
        commandRunner: any BeadsCommandRunning = ProcessBeadsCommandRunner(),
        harnessLoader: any HarnessHealthLoading = HarnessHealthService(),
        runtimeHarnessLoader: any RuntimeHarnessLoading = RuntimeHarnessService(),
        recentClosedLimit: Int = 6
    ) {
        self.commandRunner = commandRunner
        self.harnessLoader = harnessLoader
        self.runtimeHarnessLoader = runtimeHarnessLoader
        self.recentClosedLimit = recentClosedLimit
    }

    func loadSnapshot() throws -> BeadsAgentWorkSnapshot {
        let beadsPath = try commandRunner.run(["where"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ready = try decodeIssues(from: commandRunner.run(["ready", "--json"]), command: "bd ready --json")
        let inProgress = try decodeIssues(
            from: commandRunner.run(["list", "--status=in_progress", "--json"]),
            command: "bd list --status=in_progress --json"
        )
        let closed = try decodeIssues(
            from: commandRunner.run(["list", "--status=closed", "--json"]),
            command: "bd list --status=closed --json"
        )
        .sorted { left, right in
            (left.closedAt ?? left.updatedAt ?? "") > (right.closedAt ?? right.updatedAt ?? "")
        }

        return BeadsAgentWorkSnapshot(
            beadsPath: beadsPath,
            ready: ready,
            inProgress: inProgress,
            recentClosed: Array(closed.prefix(recentClosedLimit)),
            harness: harnessLoader.loadSnapshot(),
            runtimeHarness: runtimeHarnessLoader.loadSnapshot(),
            loadedAt: Date()
        )
    }

    func loadHarnessOnlySnapshot() -> BeadsAgentWorkSnapshot {
        BeadsAgentWorkSnapshot(
            beadsPath: "",
            ready: [],
            inProgress: [],
            recentClosed: [],
            harness: harnessLoader.loadSnapshot(),
            runtimeHarness: runtimeHarnessLoader.loadSnapshot(),
            loadedAt: Date()
        )
    }

    private func decodeIssues(from output: String, command: String) throws -> [BeadsIssue] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            return try JSONDecoder().decode([BeadsIssue].self, from: Data(trimmed.utf8))
        } catch {
            throw BeadsAgentWorkServiceError.invalidJSON(
                command: command,
                underlying: error.localizedDescription
            )
        }
    }
}
