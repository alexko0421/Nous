import Foundation

protocol BeadsCommandRunning {
    func run(_ arguments: [String]) throws -> String
}

enum AgentWorkRepositoryLocator {
    static let explicitRepoRootEnvironmentKey = "NOUS_REPO_ROOT"

    static func defaultWorkingDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        sourceFileURL: URL = URL(fileURLWithPath: #filePath),
        currentDirectoryURL: URL? = nil
    ) -> URL? {
        let currentDirectoryURL = currentDirectoryURL
            ?? URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)

        if let explicitPath = normalized(environment[explicitRepoRootEnvironmentKey]) {
            let explicitURL = URL(fileURLWithPath: explicitPath, isDirectory: true)
            if isRepositoryRoot(explicitURL, fileManager: fileManager) {
                return explicitURL
            }
        }

        if let current = walkUpForRepositoryRoot(from: currentDirectoryURL, fileManager: fileManager) {
            return current
        }

        if let source = walkUpForRepositoryRoot(from: sourceFileURL, fileManager: fileManager) {
            return source
        }

        for fallback in defaultFallbackURLs(fileManager: fileManager) {
            if isRepositoryRoot(fallback, fileManager: fileManager) {
                return fallback
            }
        }

        return currentDirectoryURL
    }

    private static func walkUpForRepositoryRoot(from url: URL, fileManager: FileManager) -> URL? {
        var candidate = url.hasDirectoryPath ? url : url.deletingLastPathComponent()

        while candidate.path != "/" {
            if isRepositoryRoot(candidate, fileManager: fileManager) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        return nil
    }

    private static func isRepositoryRoot(_ url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent(".beads/redirect").path) ||
            fileManager.fileExists(atPath: url.appendingPathComponent(".beads").path) ||
            fileManager.fileExists(atPath: url.appendingPathComponent("project.yml").path)
    }

    private static func defaultFallbackURLs(fileManager: FileManager) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Nous", isDirectory: true),
            home.appendingPathComponent("conductor/workspaces/Nous/new-york", isDirectory: true)
        ]
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ProcessBeadsCommandRunner: BeadsCommandRunning {
    var workingDirectoryURL: URL?
    var timeout: TimeInterval
    var executableOverride: (url: URL, argumentsPrefix: [String])?

    init(
        workingDirectoryURL: URL? = AgentWorkRepositoryLocator.defaultWorkingDirectoryURL(),
        timeout: TimeInterval = 5,
        executableOverride: (url: URL, argumentsPrefix: [String])? = nil
    ) {
        self.workingDirectoryURL = workingDirectoryURL
        self.timeout = timeout
        self.executableOverride = executableOverride
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
        let semaphore = DispatchSemaphore(value: 0)
        let outputCollector = PipeOutputCollector(pipe: stdout)
        let errorCollector = PipeOutputCollector(pipe: stderr)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
            outputCollector.startReading()
            errorCollector.startReading()
        } catch {
            throw BeadsAgentWorkServiceError.commandLaunchFailed(error.localizedDescription)
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 1)
            _ = outputCollector.waitUntilFinished(timeout: .now() + 1)
            _ = errorCollector.waitUntilFinished(timeout: .now() + 1)
            throw BeadsAgentWorkServiceError.commandTimedOut(arguments: arguments, timeout: timeout)
        }

        _ = outputCollector.waitUntilFinished(timeout: .distantFuture)
        _ = errorCollector.waitUntilFinished(timeout: .distantFuture)
        let output = outputCollector.stringValue
        let errorOutput = errorCollector.stringValue

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
        if let executableOverride {
            return executableOverride
        }

        let fileManager = FileManager.default
        for path in ["/opt/homebrew/bin/bd", "/usr/local/bin/bd"] {
            if fileManager.isExecutableFile(atPath: path) {
                return (URL(fileURLWithPath: path), [])
            }
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["bd"])
    }

}

private final class PipeOutputCollector: @unchecked Sendable {
    private let pipe: Pipe
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data = Data()

    init(pipe: Pipe) {
        self.pipe = pipe
    }

    func startReading() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [pipe] in
            let readData = pipe.fileHandleForReading.readDataToEndOfFile()
            self.lock.lock()
            self.data = readData
            self.lock.unlock()
            self.group.leave()
        }
    }

    func waitUntilFinished(timeout: DispatchTime) -> Bool {
        group.wait(timeout: timeout) == .success
    }

    var stringValue: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum BeadsAgentWorkServiceError: LocalizedError, Equatable {
    case commandLaunchFailed(String)
    case commandTimedOut(arguments: [String], timeout: TimeInterval)
    case commandFailed(arguments: [String], status: Int, stderr: String)
    case invalidJSON(command: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .commandLaunchFailed(let message):
            return "Could not launch bd: \(message)"
        case .commandTimedOut(let arguments, let timeout):
            let command = "bd " + arguments.joined(separator: " ")
            return "\(command) timed out after \(timeout)s."
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

final class BeadsAgentWorkService: @unchecked Sendable {
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
        let beadsPath = parseBeadsPath(from: try commandRunner.run(["where"]))
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
        var runtimeHarness = runtimeHarnessLoader.loadSnapshot()
        runtimeHarness.outcomeContracts = AgentOutcomeContractHealthSummary.summarize(
            (ready + inProgress).map(\.outcomeContract)
        )

        return BeadsAgentWorkSnapshot(
            beadsPath: beadsPath,
            beadsConnection: .connected(path: beadsPath),
            ready: ready,
            inProgress: inProgress,
            recentClosed: Array(closed.prefix(recentClosedLimit)),
            harness: harnessLoader.loadSnapshot(),
            runtimeHarness: runtimeHarness,
            loadedAt: Date()
        )
    }

    func loadHarnessOnlySnapshot(connectionError: String? = nil) -> BeadsAgentWorkSnapshot {
        let trimmedError = connectionError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return BeadsAgentWorkSnapshot(
            beadsPath: "",
            beadsConnection: trimmedError.isEmpty ? .unavailable : .failed(message: trimmedError),
            ready: [],
            inProgress: [],
            recentClosed: [],
            harness: harnessLoader.loadSnapshot(),
            runtimeHarness: runtimeHarnessLoader.loadSnapshot(),
            loadedAt: Date()
        )
    }

    private func parseBeadsPath(from output: String) -> String {
        let firstPathLine = output
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return firstPathLine ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
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
