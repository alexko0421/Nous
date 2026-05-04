import Foundation

struct SycophancyFixture: Codable, Equatable {
    let name: String
    let domain: String
    let userTurn: String
    let assistantDraft: String
    let expectedRiskFlags: [String]

    private enum CodingKeys: String, CodingKey {
        case name
        case domain
        case userTurn = "user_turn"
        case assistantDraft = "assistant_draft"
        case expectedRiskFlags = "expected_risk_flags"
    }

    func validated(fileStem: String) throws -> SycophancyFixture {
        guard name == fileStem else {
            throw RunnerError.invalidFixture("\(fileStem): name must match file stem")
        }

        let fields = [
            ("domain", domain),
            ("user_turn", userTurn),
            ("assistant_draft", assistantDraft)
        ]
        for field in fields where field.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RunnerError.invalidFixture("\(name): \(field.0) is empty")
        }

        guard expectedRiskFlags.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw RunnerError.invalidFixture("\(name): expected_risk_flags contains an empty flag")
        }

        return self
    }
}

struct SycophancyFixtureResult {
    let fixture: SycophancyFixture
    let actualRiskFlags: [String]

    var passed: Bool {
        Set(actualRiskFlags) == Set(fixture.expectedRiskFlags)
    }
}

enum RunnerError: Error, CustomStringConvertible {
    case usage
    case invalidFixture(String)
    case noFixtures(URL)

    var description: String {
        switch self {
        case .usage:
            return "usage: SycophancyFixtureRunner <fixtures-dir> [--dry-run] [--no-persist] [--results-dir <path>]"
        case .invalidFixture(let message):
            return message
        case .noFixtures(let url):
            return "No sycophancy fixtures found in \(url.path)"
        }
    }
}

struct RunnerOptions {
    let fixturesDirectory: URL
    let dryRun: Bool
    let persist: Bool
    let resultsDirectory: URL

    static func parse(arguments: [String]) throws -> RunnerOptions {
        guard arguments.count >= 2 else { throw RunnerError.usage }

        let fixturesDirectory = URL(fileURLWithPath: arguments[1])
        var dryRun = false
        var persist = true
        var resultsDirectory: URL?
        var index = 2

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--dry-run":
                dryRun = true
                index += 1
            case "--no-persist":
                persist = false
                index += 1
            case "--results-dir":
                guard index + 1 < arguments.count else { throw RunnerError.usage }
                resultsDirectory = URL(fileURLWithPath: arguments[index + 1])
                index += 2
            default:
                throw RunnerError.usage
            }
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return RunnerOptions(
            fixturesDirectory: fixturesDirectory,
            dryRun: dryRun,
            persist: persist,
            resultsDirectory: resultsDirectory ?? cwd.appendingPathComponent("results/sycophancy")
        )
    }
}

enum SycophancyFixtureLoader {
    static func loadAll(from directory: URL) throws -> [SycophancyFixture] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !urls.isEmpty else {
            throw RunnerError.noFixtures(directory)
        }

        return try urls.map { url in
            let fixture = try JSONDecoder().decode(
                SycophancyFixture.self,
                from: Data(contentsOf: url)
            )
            return try fixture.validated(fileStem: url.deletingPathExtension().lastPathComponent)
        }
    }
}

enum SycophancyReportPrinter {
    static func printRows(results: [SycophancyFixtureResult]) {
        for (index, result) in results.enumerated() {
            let status = result.passed ? "PASS" : "FAIL"
            print("[\(index + 1)/\(results.count)] \(status) \(result.fixture.name) actual=\(result.actualRiskFlags)")
        }
    }

    static func printSummary(runId: String, results: [SycophancyFixtureResult], persisted: Bool) {
        let passed = results.filter(\.passed).count
        print("Sycophancy fixtures: \(passed)/\(results.count) passed. run_id=\(runId) persisted=\(persisted)")
    }

    static func persist(runId: String, results: [SycophancyFixtureResult], root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let historyURL = root.appendingPathComponent("history.jsonl")

        for result in results {
            let row = [
                "run_id": runId,
                "fixture": result.fixture.name,
                "domain": result.fixture.domain,
                "passed": result.passed ? "true" : "false",
                "expected": result.fixture.expectedRiskFlags.joined(separator: ","),
                "actual": result.actualRiskFlags.joined(separator: ",")
            ]
            let line = try JSONSerialization.data(
                withJSONObject: row,
                options: [.sortedKeys]
            )
            if !FileManager.default.fileExists(atPath: historyURL.path) {
                FileManager.default.createFile(atPath: historyURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: historyURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.write(contentsOf: Data("\n".utf8))
            try handle.close()

            if !result.passed {
                try writeFailureTranscript(runId: runId, result: result, root: root)
            }
        }
    }

    private static func writeFailureTranscript(
        runId: String,
        result: SycophancyFixtureResult,
        root: URL
    ) throws {
        let failureDirectory = root
            .appendingPathComponent("failures")
            .appendingPathComponent(runId)
        try FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
        let transcript = """
        fixture: \(result.fixture.name)
        domain: \(result.fixture.domain)
        expected: \(result.fixture.expectedRiskFlags)
        actual: \(result.actualRiskFlags)

        user:
        \(result.fixture.userTurn)

        assistant:
        \(result.fixture.assistantDraft)
        """
        try transcript.write(
            to: failureDirectory.appendingPathComponent("\(result.fixture.name).txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

do {
    let options = try RunnerOptions.parse(arguments: CommandLine.arguments)
    let fixtures = try SycophancyFixtureLoader.loadAll(from: options.fixturesDirectory)

    if options.dryRun {
        print("Validated \(fixtures.count) sycophancy fixtures.")
        exit(0)
    }

    let results = fixtures.map { fixture in
        SycophancyFixtureResult(
            fixture: fixture,
            actualRiskFlags: SycophancyRiskHeuristics.riskFlags(
                user: fixture.userTurn,
                assistant: fixture.assistantDraft
            )
        )
    }
    let runId = UUID().uuidString.lowercased()
    let shouldPersist = options.persist
    SycophancyReportPrinter.printRows(results: results)
    if shouldPersist {
        try SycophancyReportPrinter.persist(runId: runId, results: results, root: options.resultsDirectory)
    }
    SycophancyReportPrinter.printSummary(runId: runId, results: results, persisted: shouldPersist)
    exit(results.allSatisfy(\.passed) ? 0 : 1)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
