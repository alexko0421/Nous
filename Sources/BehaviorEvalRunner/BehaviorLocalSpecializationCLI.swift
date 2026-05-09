import Foundation

enum CLILocalSpecialization {
    static let provider = "Local (MLX)"
    static let defaultModel = "mlx-community/Llama-3.2-3B-Instruct-4bit"

    enum Role: String, Encodable {
        case system
        case user
        case assistant
    }

    struct Message: Encodable {
        let role: Role
        let content: String
    }

    struct Metadata: Encodable {
        let caseId: String
        let axis: BehaviorDatasetAxis
        let origin: BehaviorDatasetOrigin
        let sourceCaseId: String?
        let tags: [String]
        let generator: String?
        let variantIndex: Int?
        let failureReason: String
        let createdAt: Date
    }

    struct FineTuneRecord: Encodable {
        let id: String
        let messages: [Message]
        let metadata: Metadata
    }

    struct ExportOptions {
        var resultsDir = "results/behavior_eval"
        var output: String?
        var includeGenerated = true
    }

    struct EvalOptions {
        var model: String?
        var mode = "quick"
        var live = "never"
        var resultsDir = "results/behavior_eval"
        var changeSignature: String?
    }

    struct EvalOutcome {
        let detail: String
        let failed: Bool
        let resultsDir: String
    }
}

func runLocalExportCommand(_ arguments: [String]) throws -> String {
    let options = try parseLocalExportOptions(arguments)
    let resultsDirectory = URL(fileURLWithPath: options.resultsDir, isDirectory: true)
    let outputURL = URL(
        fileURLWithPath: options.output ?? "\(options.resultsDir)/exports/behavior_finetune.jsonl"
    )
    let cases = try loadBehaviorDatasetCases(
        resultsDirectory: resultsDirectory,
        includeGenerated: options.includeGenerated
    )
    let records = cases.map(localFineTuneRecord(from:))
    try writeLocalFineTuneRecords(records, to: outputURL)

    let incidentCount = cases.filter { $0.origin == .incident }.count
    let generatedCount = cases.filter { $0.origin == .generated }.count
    return "local specialization export wrote \(records.count) records (\(incidentCount) incident, \(generatedCount) generated) to \(outputURL.path)"
}

func runLocalEvalCommand(_ arguments: [String]) throws -> CLILocalSpecialization.EvalOutcome {
    let options = try parseLocalEvalOptions(arguments)
    guard let model = nonEmpty(options.model) else {
        throw CLIError.missingValue("--model")
    }

    var results = localize(results: deterministicResults(), model: model)
    if options.live == "never" {
        results.append(localGenerationNotExercisedResult(model: model))
    } else if options.live == "auto" {
        results.append(localLiveSkippedResult(model: model))
    } else if options.live == "required" {
        results.append(localLiveUnavailableResult(model: model))
    }

    let initialStatus = runStatus(results)
    let score = trustScore(results)
    let comparison = baselineComparison(
        currentTrustScore: score,
        currentStatus: initialStatus,
        baseline: trustedBaseline(
            resultsDir: options.resultsDir,
            mode: options.mode,
            live: options.live,
            provider: CLILocalSpecialization.provider,
            model: model
        )
    )
    let regression = comparison.regression
    let status = regression ? "failed" : initialStatus
    let runId = UUID().uuidString.lowercased()
    let formatter = ISO8601DateFormatter()
    let endedAt = Date()
    let detail = localEvalDetail(
        mode: options.mode,
        status: status,
        trustScore: score,
        comparison: comparison
    )

    let runRecord = CLIBehaviorEval.RunRecord(
        id: runId,
        mode: options.mode,
        liveMode: options.live,
        status: status,
        trustScore: score,
        startedAt: formatter.string(from: startedAt),
        endedAt: formatter.string(from: endedAt),
        provider: CLILocalSpecialization.provider,
        model: model,
        changeSignature: options.changeSignature,
        baselineRunId: comparison.baselineRunId,
        baselineTrustScore: comparison.baselineTrustScore,
        trustScoreDelta: comparison.trustScoreDelta,
        regression: regression,
        detail: detail
    )
    try persist(run: runRecord, results: results, resultsDir: options.resultsDir)

    return CLILocalSpecialization.EvalOutcome(
        detail: detail,
        failed: status == "failed",
        resultsDir: options.resultsDir
    )
}

func parseLocalExportOptions(_ arguments: [String]) throws -> CLILocalSpecialization.ExportOptions {
    var options = CLILocalSpecialization.ExportOptions()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--results-dir":
            options.resultsDir = try value(after: argument, in: arguments, index: &index)
        case "--output":
            options.output = try value(after: argument, in: arguments, index: &index)
        case "--include-generated":
            options.includeGenerated = try parseBool(
                value(after: argument, in: arguments, index: &index),
                flag: argument
            )
        case "--help", "-h":
            print("usage: BehaviorEvalRunner export-local [--results-dir path] [--output path] [--include-generated true|false]")
            exit(0)
        default:
            throw CLIError.invalidArgument(argument)
        }
        index += 1
    }
    return options
}

func parseLocalEvalOptions(_ arguments: [String]) throws -> CLILocalSpecialization.EvalOptions {
    var options = CLILocalSpecialization.EvalOptions()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--model":
            options.model = try value(after: argument, in: arguments, index: &index)
        case "--mode":
            options.mode = try value(after: argument, in: arguments, index: &index)
        case "--live":
            options.live = try value(after: argument, in: arguments, index: &index)
        case "--results-dir":
            options.resultsDir = try value(after: argument, in: arguments, index: &index)
        case "--change-signature":
            options.changeSignature = try value(after: argument, in: arguments, index: &index)
        case "--help", "-h":
            print("usage: BehaviorEvalRunner local-eval --model local-model-id --mode quick|full --live never|auto|required")
            exit(0)
        default:
            throw CLIError.invalidArgument(argument)
        }
        index += 1
    }

    guard ["quick", "full"].contains(options.mode) else {
        throw CLIError.invalidArgument("--mode \(options.mode)")
    }
    guard ["never", "auto", "required"].contains(options.live) else {
        throw CLIError.invalidArgument("--live \(options.live)")
    }
    return options
}

func parseBool(_ rawValue: String, flag: String) throws -> Bool {
    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true", "yes", "1":
        return true
    case "false", "no", "0":
        return false
    default:
        throw CLIError.invalidArgument("\(flag) \(rawValue)")
    }
}

func loadBehaviorDatasetCases(
    resultsDirectory: URL,
    includeGenerated: Bool
) throws -> [BehaviorDatasetCase] {
    let datasetDirectory = resultsDirectory.appendingPathComponent(
        BehaviorDatasetStudio.datasetDirectoryName,
        isDirectory: true
    )
    var cases = try loadBehaviorDatasetCases(
        from: datasetDirectory.appendingPathComponent(BehaviorDatasetStudio.incidentFileName)
    )
    if includeGenerated {
        cases += try loadBehaviorDatasetCases(
            from: datasetDirectory.appendingPathComponent(BehaviorDatasetStudio.generatedFileName)
        )
    }
    try validateBehaviorDatasetCases(cases)
    return cases
}

func loadBehaviorDatasetCases(from url: URL) throws -> [BehaviorDatasetCase] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let contents = try String(contentsOf: url, encoding: .utf8)
    return try contents.split(separator: "\n").map { line in
        guard let data = String(line).data(using: .utf8),
              let behaviorCase = try? decoder.decode(BehaviorDatasetCase.self, from: data) else {
            throw BehaviorDatasetStudioError.invalidDatasetLine(url.lastPathComponent)
        }
        return behaviorCase
    }
}

func validateBehaviorDatasetCases(_ cases: [BehaviorDatasetCase]) throws {
    guard !cases.isEmpty else {
        throw CLIError.invalidResponse("no behavior dataset cases to export")
    }
    var seenCaseIds = Set<String>()
    var incidentIds = Set<String>()
    for behaviorCase in cases {
        guard let caseId = nonEmpty(behaviorCase.id) else {
            throw BehaviorDatasetStudioError.invalidCaseId(behaviorCase.id)
        }
        guard seenCaseIds.insert(caseId).inserted else {
            throw BehaviorDatasetStudioError.duplicateCaseId(caseId)
        }
        try validateBehaviorDatasetContent(behaviorCase.user, field: "user", id: caseId)
        try validateBehaviorDatasetContent(behaviorCase.assistant, field: "assistant", id: caseId)
        try validateBehaviorDatasetContent(behaviorCase.expectedBehavior, field: "expectedBehavior", id: caseId)
        try validateBehaviorDatasetContent(behaviorCase.failureReason, field: "failureReason", id: caseId)
        if behaviorCase.origin == .incident {
            incidentIds.insert(caseId)
        }
    }

    for behaviorCase in cases where behaviorCase.origin == .generated {
        guard let sourceCaseId = nonEmpty(behaviorCase.sourceCaseId),
              incidentIds.contains(sourceCaseId) else {
            throw BehaviorDatasetStudioError.orphanGeneratedCase(
                id: behaviorCase.id,
                sourceCaseId: behaviorCase.sourceCaseId
            )
        }
    }
}

func validateBehaviorDatasetContent(
    _ content: String,
    field: String,
    id: String
) throws {
    guard nonEmpty(content) != nil else {
        throw CLIError.invalidResponse("behavior dataset case \(id) has empty \(field)")
    }
}

func localFineTuneRecord(from behaviorCase: BehaviorDatasetCase) -> CLILocalSpecialization.FineTuneRecord {
    CLILocalSpecialization.FineTuneRecord(
        id: behaviorCase.id,
        messages: [
            CLILocalSpecialization.Message(
                role: .system,
                content: "Produce a corrected Nous assistant reply that preserves honesty, source boundaries, current user intent, and the expected behavior."
            ),
            CLILocalSpecialization.Message(
                role: .user,
                content: """
                User turn:
                \(behaviorCase.user)

                Rejected assistant reply:
                \(behaviorCase.assistant)

                Failure reason:
                \(behaviorCase.failureReason)
                """
            ),
            CLILocalSpecialization.Message(
                role: .assistant,
                content: behaviorCase.expectedBehavior
            )
        ],
        metadata: CLILocalSpecialization.Metadata(
            caseId: behaviorCase.id,
            axis: behaviorCase.axis,
            origin: behaviorCase.origin,
            sourceCaseId: behaviorCase.sourceCaseId,
            tags: behaviorCase.tags,
            generator: behaviorCase.generator,
            variantIndex: behaviorCase.variantIndex,
            failureReason: behaviorCase.failureReason,
            createdAt: behaviorCase.createdAt
        )
    )
}

func writeLocalFineTuneRecords(
    _ records: [CLILocalSpecialization.FineTuneRecord],
    to outputURL: URL
) throws {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let payload = try records
        .map { try encodeLocalJSONL($0) }
        .joined(separator: "\n")
    try Data((payload + (records.isEmpty ? "" : "\n")).utf8).write(to: outputURL)
}

func localize(
    results: [CLIBehaviorEval.Result],
    model: String
) -> [CLIBehaviorEval.Result] {
    results.map { result in
        CLIBehaviorEval.Result(
            id: result.id,
            axis: result.axis,
            verdict: result.verdict,
            findings: result.findings,
            provider: CLILocalSpecialization.provider,
            model: model
        )
    }
}

func localLiveUnavailableResult(model: String) -> CLIBehaviorEval.Result {
    CLIBehaviorEval.Result(
        id: "local_live_generation_unavailable",
        axis: "live_generation",
        verdict: "failure",
        findings: [
            CLIBehaviorEval.Finding(
                code: "local_live_generation_unavailable",
                severity: "failure",
                message: "Local live generation is not wired into the behavior eval CLI yet; run local eval with --live never or evaluate the model outside the app before import."
            )
        ],
        provider: CLILocalSpecialization.provider,
        model: model
    )
}

func localLiveSkippedResult(model: String) -> CLIBehaviorEval.Result {
    CLIBehaviorEval.Result(
        id: "local_live_generation_unavailable",
        axis: "live_generation",
        verdict: "warning",
        findings: [
            CLIBehaviorEval.Finding(
                code: "local_live_generation_unavailable",
                severity: "warning",
                message: "Local live generation is not wired into the behavior eval CLI yet; this run does not prove the model is trusted."
            )
        ],
        provider: CLILocalSpecialization.provider,
        model: model
    )
}

func localGenerationNotExercisedResult(model: String) -> CLIBehaviorEval.Result {
    CLIBehaviorEval.Result(
        id: "local_generation_not_exercised",
        axis: "live_generation",
        verdict: "warning",
        findings: [
            CLIBehaviorEval.Finding(
                code: "local_generation_not_exercised",
                severity: "warning",
                message: "This local-model run only covered deterministic harness signals; no local generation result was recorded, so the model is not proven trusted."
            )
        ],
        provider: CLILocalSpecialization.provider,
        model: model
    )
}

func localEvalDetail(
    mode: String,
    status: String,
    trustScore: Int,
    comparison: (
        baselineRunId: String?,
        baselineTrustScore: Int?,
        trustScoreDelta: Int?,
        regression: Bool
    )
) -> String {
    var detail = "local \(mode) behavior eval for \(CLILocalSpecialization.provider) \(status) with trust score \(trustScore)."
    if let baseline = comparison.baselineTrustScore,
       let delta = comparison.trustScoreDelta {
        detail += " Baseline trust score \(baseline), delta \(delta)."
    }
    if comparison.regression {
        detail += " Regression against previous trusted baseline."
    }
    return detail
}

func encodeLocalJSONL<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard let line = String(data: data, encoding: .utf8) else {
        throw EncodingError.invalidValue(
            value,
            EncodingError.Context(
                codingPath: [],
                debugDescription: "Local specialization JSON was not valid UTF-8."
            )
        )
    }
    return line.replacingOccurrences(of: "\n", with: "")
}
