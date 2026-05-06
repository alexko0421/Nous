import Foundation

enum BehaviorFineTuneExportError: LocalizedError, Equatable {
    case emptyDataset
    case duplicateCaseId(String)
    case invalidCaseId(String)
    case invalidCaseContent(id: String, field: String)
    case invalidDatasetLine(String)
    case orphanGeneratedCase(id: String, sourceCaseId: String?)

    var errorDescription: String? {
        switch self {
        case .emptyDataset:
            return "behavior fine-tune export has no cases"
        case let .duplicateCaseId(id):
            return "duplicate behavior fine-tune case id: \(id)"
        case let .invalidCaseId(id):
            return "invalid behavior fine-tune case id: \(id)"
        case let .invalidCaseContent(id, field):
            return "behavior fine-tune case \(id) has empty \(field)"
        case let .invalidDatasetLine(fileName):
            return "invalid behavior dataset JSONL line in \(fileName)"
        case let .orphanGeneratedCase(id, sourceCaseId):
            let source = sourceCaseId ?? "nil"
            return "generated behavior fine-tune case \(id) references missing incident source \(source)"
        }
    }
}

enum BehaviorFineTuneExporter {
    static let defaultFileName = "behavior_finetune.jsonl"

    static func record(from behaviorCase: BehaviorDatasetCase) -> BehaviorFineTuneRecord {
        BehaviorFineTuneRecord(
            id: behaviorCase.id,
            messages: [
                BehaviorFineTuneMessage(
                    role: .system,
                    content: "Produce a corrected Nous assistant reply that preserves honesty, source boundaries, current user intent, and the expected behavior."
                ),
                BehaviorFineTuneMessage(
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
                BehaviorFineTuneMessage(
                    role: .assistant,
                    content: behaviorCase.expectedBehavior
                )
            ],
            metadata: BehaviorFineTuneMetadata(
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

    static func records(from cases: [BehaviorDatasetCase]) -> [BehaviorFineTuneRecord] {
        cases.map(record(from:))
    }

    static func loadCases(
        resultsDirectory: URL,
        includeGenerated: Bool = true
    ) throws -> [BehaviorDatasetCase] {
        let datasetDirectory = resultsDirectory.appendingPathComponent(
            BehaviorDatasetStudio.datasetDirectoryName,
            isDirectory: true
        )
        var cases = try loadCases(
            from: datasetDirectory.appendingPathComponent(BehaviorDatasetStudio.incidentFileName)
        )
        if includeGenerated {
            cases += try loadCases(
                from: datasetDirectory.appendingPathComponent(BehaviorDatasetStudio.generatedFileName)
            )
        }
        try validateCases(cases)
        return cases
    }

    @discardableResult
    static func export(
        cases: [BehaviorDatasetCase],
        to outputURL: URL
    ) throws -> BehaviorFineTuneExportSummary {
        try validateCases(cases)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let records = records(from: cases)
        let payload = try records
            .map { try encodeJSONL($0) }
            .joined(separator: "\n")
        let data = Data((payload + (records.isEmpty ? "" : "\n")).utf8)
        try data.write(to: outputURL)

        return BehaviorFineTuneExportSummary(
            recordCount: records.count,
            incidentCount: cases.filter { $0.origin == .incident }.count,
            generatedCount: cases.filter { $0.origin == .generated }.count,
            outputURL: outputURL
        )
    }

    private static func loadCases(from url: URL) throws -> [BehaviorDatasetCase] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents = try String(contentsOf: url, encoding: .utf8)
        return try contents.split(separator: "\n").map { line in
            guard let data = String(line).data(using: .utf8),
                  let behaviorCase = try? decoder.decode(BehaviorDatasetCase.self, from: data) else {
                throw BehaviorFineTuneExportError.invalidDatasetLine(url.lastPathComponent)
            }
            return behaviorCase
        }
    }

    private static func validateCases(_ cases: [BehaviorDatasetCase]) throws {
        guard !cases.isEmpty else {
            throw BehaviorFineTuneExportError.emptyDataset
        }
        var seenCaseIds = Set<String>()
        var incidentIds = Set<String>()
        for behaviorCase in cases {
            let caseId = behaviorCase.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !caseId.isEmpty else {
                throw BehaviorFineTuneExportError.invalidCaseId(behaviorCase.id)
            }
            guard seenCaseIds.insert(caseId).inserted else {
                throw BehaviorFineTuneExportError.duplicateCaseId(caseId)
            }
            try validateNonEmptyContent(behaviorCase.user, field: "user", id: caseId)
            try validateNonEmptyContent(behaviorCase.assistant, field: "assistant", id: caseId)
            try validateNonEmptyContent(behaviorCase.expectedBehavior, field: "expectedBehavior", id: caseId)
            try validateNonEmptyContent(behaviorCase.failureReason, field: "failureReason", id: caseId)
            if behaviorCase.origin == .incident {
                incidentIds.insert(caseId)
            }
        }

        for behaviorCase in cases where behaviorCase.origin == .generated {
            guard let sourceCaseId = validSourceCaseId(behaviorCase.sourceCaseId),
                  incidentIds.contains(sourceCaseId) else {
                throw BehaviorFineTuneExportError.orphanGeneratedCase(
                    id: behaviorCase.id,
                    sourceCaseId: behaviorCase.sourceCaseId
                )
            }
        }
    }

    private static func validateNonEmptyContent(
        _ content: String,
        field: String,
        id: String
    ) throws {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BehaviorFineTuneExportError.invalidCaseContent(id: id, field: field)
        }
    }

    private static func validSourceCaseId(_ id: String?) -> String? {
        guard let id,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return id.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func encodeJSONL<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let line = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Behavior fine-tune JSON was not valid UTF-8."
                )
            )
        }
        return line.replacingOccurrences(of: "\n", with: "")
    }
}
