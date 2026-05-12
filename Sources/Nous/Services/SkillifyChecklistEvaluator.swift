import Foundation

enum SkillifyChecklistItem: String, Codable, Equatable, CaseIterable {
    case failureSignature
    case rootCause
    case trigger
    case useWhen
    case antiPatternExample
    case regressionTestReference
    case resolverTestReference
    case smokeTestCommand
    case codeReference
    case proposedSkillPayload
}

enum SkillifyChecklistBlockingReason: String, Codable, Equatable {
    case incompleteChecklist
    case deterministicFixCannotActivateSkill
    case missingSkillPayload
    case invalidSkillPayload
    case invalidRegressionTestReference
    case invalidResolverTestReference
    case invalidSmokeTestCommand
}

struct SkillifyChecklistEvaluation: Equatable {
    let canActivate: Bool
    let completedCount: Int
    let requiredCount: Int
    let missingItems: [SkillifyChecklistItem]
    let blockingReason: SkillifyChecklistBlockingReason?

    var scoreText: String {
        "\(completedCount)/\(requiredCount)"
    }
}

struct SkillifyChecklistEvaluator {
    func evaluate(_ candidate: FailureSkillCandidate) -> SkillifyChecklistEvaluation {
        let requiredItems = requiredItems(for: candidate)
        let missing = requiredItems.filter { !isComplete($0, candidate: candidate) }
        guard missing.isEmpty else {
            return SkillifyChecklistEvaluation(
                canActivate: false,
                completedCount: requiredItems.count - missing.count,
                requiredCount: requiredItems.count,
                missingItems: missing,
                blockingReason: .incompleteChecklist
            )
        }

        guard testReferenceExists(candidate.checklist.regressionTestReference) else {
            return SkillifyChecklistEvaluation(
                canActivate: false,
                completedCount: requiredItems.count,
                requiredCount: requiredItems.count,
                missingItems: [],
                blockingReason: .invalidRegressionTestReference
            )
        }

        guard testReferenceExists(candidate.checklist.resolverTestReference) else {
            return SkillifyChecklistEvaluation(
                canActivate: false,
                completedCount: requiredItems.count,
                requiredCount: requiredItems.count,
                missingItems: [],
                blockingReason: .invalidResolverTestReference
            )
        }

        guard smokeCommandIsValid(
            candidate.checklist.smokeTestCommand,
            regressionReference: candidate.checklist.regressionTestReference,
            resolverReference: candidate.checklist.resolverTestReference
        ) else {
            return SkillifyChecklistEvaluation(
                canActivate: false,
                completedCount: requiredItems.count,
                requiredCount: requiredItems.count,
                missingItems: [],
                blockingReason: .invalidSmokeTestCommand
            )
        }

        guard candidate.repairKind == .promptSkill else {
            let reason: SkillifyChecklistBlockingReason? = candidate.repairKind == .deterministicFix
                ? .deterministicFixCannotActivateSkill
                : .incompleteChecklist
            return SkillifyChecklistEvaluation(
                canActivate: false,
                completedCount: requiredItems.count,
                requiredCount: requiredItems.count,
                missingItems: [],
                blockingReason: reason
            )
        }

        guard let payload = candidate.proposedSkillPayload else {
            return SkillifyChecklistEvaluation(
                canActivate: false,
                completedCount: requiredItems.count,
                requiredCount: requiredItems.count,
                missingItems: [.proposedSkillPayload],
                blockingReason: .missingSkillPayload
            )
        }

        do {
            try SkillPayloadValidator.validate(payload)
        } catch {
            return SkillifyChecklistEvaluation(
                canActivate: false,
                completedCount: requiredItems.count,
                requiredCount: requiredItems.count,
                missingItems: [],
                blockingReason: .invalidSkillPayload
            )
        }

        return SkillifyChecklistEvaluation(
            canActivate: true,
            completedCount: requiredItems.count,
            requiredCount: requiredItems.count,
            missingItems: [],
            blockingReason: nil
        )
    }

    private func requiredItems(for candidate: FailureSkillCandidate) -> [SkillifyChecklistItem] {
        var items: [SkillifyChecklistItem] = [
            .failureSignature,
            .rootCause,
            .trigger,
            .useWhen,
            .antiPatternExample,
            .regressionTestReference,
            .resolverTestReference,
            .smokeTestCommand
        ]
        if candidate.repairKind == .deterministicFix {
            items.append(.codeReference)
        }
        if candidate.repairKind == .promptSkill {
            items.append(.proposedSkillPayload)
        }
        return items
    }

    private func isComplete(
        _ item: SkillifyChecklistItem,
        candidate: FailureSkillCandidate
    ) -> Bool {
        switch item {
        case .failureSignature:
            return true
        case .rootCause:
            return hasText(candidate.checklist.rootCause)
        case .trigger:
            return hasText(candidate.checklist.trigger)
        case .useWhen:
            return hasText(candidate.checklist.useWhen)
        case .antiPatternExample:
            return hasText(candidate.checklist.antiPatternExample)
        case .regressionTestReference:
            return hasText(candidate.checklist.regressionTestReference)
        case .resolverTestReference:
            return hasText(candidate.checklist.resolverTestReference)
        case .smokeTestCommand:
            return hasText(candidate.checklist.smokeTestCommand)
        case .codeReference:
            return hasText(candidate.checklist.codeReference)
        case .proposedSkillPayload:
            return candidate.proposedSkillPayload != nil
        }
    }

    private func hasText(_ value: String?) -> Bool {
        !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func testReferenceExists(_ value: String?) -> Bool {
        let reference = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return false }

        let parts = reference.split(separator: ".", maxSplits: 1).map(String.init)
        guard let className = parts.first,
              !className.isEmpty else {
            return false
        }

        let fileURL = repositoryRoot()
            .appendingPathComponent("Tests")
            .appendingPathComponent("NousTests")
            .appendingPathComponent("\(className).swift")
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return false
        }

        guard parts.count == 2 else { return true }
        return content.contains("func \(parts[1])(")
    }

    private func smokeCommandIsValid(
        _ value: String?,
        regressionReference: String?,
        resolverReference: String?
    ) -> Bool {
        let command = normalizedCommand(value ?? "")
        guard !command.isEmpty,
              !containsShellChaining(command),
              command.hasPrefix("xcodebuild test "),
              command.contains("-project Nous.xcodeproj"),
              command.contains("-scheme NousTests"),
              let regressionTarget = onlyTestingTarget(for: regressionReference),
              let resolverTarget = onlyTestingTarget(for: resolverReference) else {
            return false
        }

        let tokens = command.split(separator: " ").map(String.init)
        return tokens.contains("-only-testing:\(regressionTarget)")
            && tokens.contains("-only-testing:\(resolverTarget)")
            && tokens.contains { token in
                token == "-only-testing:NousTests/SkillifyChecklistEvaluatorTests"
                    || token.hasPrefix("-only-testing:NousTests/SkillifyChecklistEvaluatorTests/")
            }
    }

    private func normalizedCommand(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsShellChaining(_ value: String) -> Bool {
        ["&&", "||", ";", "`", "$(", "|", ">", "<"].contains { value.contains($0) }
    }

    private func onlyTestingTarget(for reference: String?) -> String? {
        let trimmed = (reference ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ".", maxSplits: 1).map(String.init)
        guard let className = parts.first,
              !className.isEmpty else {
            return nil
        }
        guard parts.count == 2 else {
            return "NousTests/\(className)"
        }
        guard !parts[1].isEmpty else { return nil }
        return "NousTests/\(className)/\(parts[1])"
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
