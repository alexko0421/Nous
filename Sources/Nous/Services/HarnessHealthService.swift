import Foundation

protocol HarnessHealthLoading {
    func loadSnapshot() -> HarnessHealthSnapshot
}

protocol RuntimeHarnessLoading {
    func loadSnapshot() -> RuntimeHarnessSnapshot
}

final class HarnessHealthService: HarnessHealthLoading {
    private let repoURL: URL
    private let fileManager: FileManager

    init(
        repoURL: URL? = HarnessHealthService.defaultRepoURL(),
        fileManager: FileManager = .default
    ) {
        self.repoURL = repoURL ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
        self.fileManager = fileManager
    }

    func loadSnapshot() -> HarnessHealthSnapshot {
        let classification = HarnessChangeClassifier.classify(
            changedPaths: changedPaths(),
            rootSwiftFiles: rootSwiftFiles(),
            changeSignature: changeSignature()
        )

        return HarnessHealthSnapshot(
            recentRuns: recentRuns(),
            changeClassification: classification
        )
    }

    private func changedPaths() -> [String] {
        let tracked = (try? gitOutput(["diff", "--name-only"])) ?? ""
        let staged = (try? gitOutput(["diff", "--cached", "--name-only"])) ?? ""
        let untracked = (try? gitOutput(["ls-files", "--others", "--exclude-standard"])) ?? ""
        return (tracked + "\n" + staged + "\n" + untracked)
            .split(separator: "\n")
            .map(String.init)
            .map(normalize)
            .filter { !$0.isEmpty }
    }

    private func changeSignature() -> String? {
        let script = """
        {
          git diff --binary --no-ext-diff
          printf '\\n--STAGED--\\n'
          git diff --cached --binary --no-ext-diff
          printf '\\n--UNTRACKED--\\n'
          git ls-files --others --exclude-standard | LC_ALL=C sort | while IFS= read -r path; do
            printf 'untracked:%s\\n' "$path"
            if [ -f "$path" ]; then
              shasum -a 256 "$path"
            fi
          done
          printf '\\n--ROOT-SWIFT--\\n'
          find Sources/Nous -maxdepth 1 -name "*.swift" -type f -print | LC_ALL=C sort | while IFS= read -r path; do
            printf 'root-swift:%s\\n' "$path"
            shasum -a 256 "$path"
          done
        } | shasum -a 256 | awk '{print $1}'
        """
        return (try? shellOutput(script)).map(normalize).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func rootSwiftFiles() -> [String] {
        let sourcesURL = repoURL.appendingPathComponent("Sources/Nous")
        guard let enumerator = fileManager.enumerator(
            at: sourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { relativePath(for: $0) }
            .sorted()
    }

    private func recentRuns(limit: Int = 12) -> [HarnessRunRecord] {
        let logURL = repoURL.appendingPathComponent("results/harness/runs.jsonl")
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return text
            .split(separator: "\n")
            .suffix(limit)
            .compactMap { line in
                try? decoder.decode(HarnessRunRecord.self, from: Data(line.utf8))
            }
            .sorted { $0.endedAt > $1.endedAt }
    }

    private func gitOutput(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = repoURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return ""
        }

        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func shellOutput(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = repoURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return ""
        }

        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func relativePath(for url: URL) -> String {
        let repoPath = repoURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(repoPath + "/") else {
            return filePath
        }
        return String(filePath.dropFirst(repoPath.count + 1))
    }

    private func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func defaultRepoURL() -> URL? {
        let sourceURL = URL(fileURLWithPath: #filePath)
        var candidate = sourceURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        while candidate.path != "/" {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        return nil
    }
}

final class RuntimeHarnessService: RuntimeHarnessLoading {
    private let telemetry: GovernanceTelemetryStore
    private let repoURL: URL

    private struct SycophancyHistoryRow {
        let runId: String
        let passed: Bool
    }

    init(
        telemetry: GovernanceTelemetryStore = GovernanceTelemetryStore(),
        repoURL: URL? = RuntimeHarnessService.defaultRepoURL(),
        fileManager: FileManager = .default
    ) {
        self.telemetry = telemetry
        self.repoURL = repoURL ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
    }

    func loadSnapshot() -> RuntimeHarnessSnapshot {
        let summary = telemetry.turnCognitionSummary
        return RuntimeHarnessSnapshot(
            totalTurnCount: summary.totalTurnCount,
            reviewedTurnCount: summary.reviewedTurnCount,
            reviewerCoverageRate: summary.reviewCoverageRate,
            riskFlagCounts: summary.reviewRiskFlagCounts,
            lastRiskFlags: summary.lastSnapshot?.reviewRiskFlags ?? [],
            sycophancyFixtureTrend: sycophancyFixtureTrend()
        )
    }

    private func sycophancyFixtureTrend() -> String {
        let historyURL = repoURL.appendingPathComponent("results/sycophancy/history.jsonl")
        guard let data = try? Data(contentsOf: historyURL),
              let text = String(data: data, encoding: .utf8) else {
            return "No fixture history yet"
        }

        let rows = text
            .split(separator: "\n")
            .compactMap { line -> SycophancyHistoryRow? in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let runId = object["run_id"] as? String else {
                    return nil
                }
                return SycophancyHistoryRow(
                    runId: runId,
                    passed: Self.historyBoolValue(object["passed"])
                )
            }

        guard let latestRunId = rows.last?.runId else {
            return "No fixture history yet"
        }

        let latestRows = rows.filter { $0.runId == latestRunId }
        let passed = latestRows.filter(\.passed).count
        return "\(passed)/\(latestRows.count) sycophancy fixtures passing"
    }

    private static func historyBoolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        if let string = value as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "true" || normalized == "1" || normalized == "yes"
        }

        return false
    }

    private static func defaultRepoURL() -> URL? {
        let sourceURL = URL(fileURLWithPath: #filePath)
        var candidate = sourceURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        while candidate.path != "/" {
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        return nil
    }
}
