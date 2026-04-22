import Foundation

struct JudgeFeedbackLoop: Equatable {
    struct Aggregate: Equatable {
        var upCount: Int
        var downCount: Int
        var weightedUp: Double
        var weightedDown: Double

        init(
            upCount: Int = 0,
            downCount: Int = 0,
            weightedUp: Double = 0,
            weightedDown: Double = 0
        ) {
            self.upCount = upCount
            self.downCount = downCount
            self.weightedUp = weightedUp
            self.weightedDown = weightedDown
        }

        var totalCount: Int { upCount + downCount }
        var isEmpty: Bool { totalCount == 0 && weightedUp == 0 && weightedDown == 0 }
        var downBias: Double { weightedDown - weightedUp }
    }

    struct Sample: Equatable {
        let feedback: JudgeFeedback
        let provocationKind: ProvocationKind
        let entryId: String?
        let reason: JudgeFeedbackReason?

        init(
            feedback: JudgeFeedback,
            provocationKind: ProvocationKind,
            entryId: String?,
            reason: JudgeFeedbackReason? = nil
        ) {
            self.feedback = feedback
            self.provocationKind = provocationKind
            self.entryId = entryId
            self.reason = reason
        }
    }

    struct NoteSample: Equatable {
        let reason: JudgeFeedbackReason?
        let note: String
    }

    let overall: Aggregate
    let byKind: [ProvocationKind: Aggregate]
    let downvotedEntryIds: [String]
    let stronglySuppressedEntryIds: [String]
    let negativeReasonWeights: [JudgeFeedbackReason: Double]
    let recentNegativeNotes: [NoteSample]
    let mostRecent: Sample?

    static let empty = JudgeFeedbackLoop(
        overall: Aggregate(),
        byKind: [:],
        downvotedEntryIds: [],
        stronglySuppressedEntryIds: [],
        negativeReasonWeights: [:],
        recentNegativeNotes: [],
        mostRecent: nil
    )

    var isEmpty: Bool {
        overall.isEmpty
    }

    init(
        overall: Aggregate,
        byKind: [ProvocationKind: Aggregate],
        downvotedEntryIds: [String],
        stronglySuppressedEntryIds: [String] = [],
        negativeReasonWeights: [JudgeFeedbackReason: Double] = [:],
        recentNegativeNotes: [NoteSample] = [],
        mostRecent: Sample?
    ) {
        self.overall = overall
        self.byKind = byKind
        self.downvotedEntryIds = downvotedEntryIds
        self.stronglySuppressedEntryIds = stronglySuppressedEntryIds
        self.negativeReasonWeights = negativeReasonWeights
        self.recentNegativeNotes = recentNegativeNotes
        self.mostRecent = mostRecent
    }

    init(events: [JudgeEvent], now: Date = Date()) {
        var overall = Aggregate()
        var byKind: [ProvocationKind: Aggregate] = [:]
        var downvotedEntryIds: [String] = []
        var mostRecent: Sample?
        var entryPenalty: [String: Double] = [:]
        var negativeReasonWeights: [JudgeFeedbackReason: Double] = [:]
        var recentNegativeNotes: [NoteSample] = []

        for event in events {
            guard event.fallbackReason == .ok,
                  let feedback = event.userFeedback,
                  let verdictData = event.verdictJSON.data(using: .utf8),
                  let verdict = try? JSONDecoder().decode(JudgeVerdict.self, from: verdictData),
                  verdict.shouldProvoke else {
                continue
            }

            if mostRecent == nil {
                mostRecent = Sample(
                    feedback: feedback,
                    provocationKind: verdict.provocationKind,
                    entryId: verdict.entryId,
                    reason: event.feedbackReason
                )
            }

            let ageDays = max(0, now.timeIntervalSince(event.feedbackTs ?? event.ts) / 86_400)
            let decay = pow(0.85, ageDays)
            let upWeight = decay
            let downWeight = 3 * decay

            var aggregate = byKind[verdict.provocationKind, default: Aggregate()]

            switch feedback {
            case .up:
                overall.upCount += 1
                overall.weightedUp += upWeight
                aggregate.upCount += 1
                aggregate.weightedUp += upWeight
                if let entryId = verdict.entryId {
                    entryPenalty[entryId, default: 0] -= upWeight
                }
            case .down:
                overall.downCount += 1
                overall.weightedDown += downWeight
                aggregate.downCount += 1
                aggregate.weightedDown += downWeight
                if let entryId = verdict.entryId {
                    if !downvotedEntryIds.contains(entryId) {
                        downvotedEntryIds.append(entryId)
                    }
                    entryPenalty[entryId, default: 0] += downWeight
                }
                if let reason = event.feedbackReason {
                    negativeReasonWeights[reason, default: 0] += downWeight
                }
                if recentNegativeNotes.count < 3,
                   let note = Self.normalizeNote(event.feedbackNote) {
                    recentNegativeNotes.append(
                        NoteSample(reason: event.feedbackReason, note: note)
                    )
                }
            }

            byKind[verdict.provocationKind] = aggregate
        }

        let stronglySuppressedEntryIds = entryPenalty
            .filter { $0.value >= 1.5 }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .map(\.key)

        self.init(
            overall: overall,
            byKind: byKind,
            downvotedEntryIds: downvotedEntryIds,
            stronglySuppressedEntryIds: stronglySuppressedEntryIds,
            negativeReasonWeights: negativeReasonWeights,
            recentNegativeNotes: recentNegativeNotes,
            mostRecent: mostRecent
        )
    }

    var promptBlock: String {
        guard !isEmpty else { return "(none — no explicit thumbs feedback yet)" }

        var lines = [
            "overall explicit feedback: \(overall.upCount) up / \(overall.downCount) down",
            "overall weighted feedback: \(Self.format(overall.weightedUp)) up / \(Self.format(overall.weightedDown)) down"
        ]

        if let mostRecent {
            var line = "most recent explicit feedback: \(mostRecent.feedback.rawValue) on \(mostRecent.provocationKind.rawValue)"
            if let entryId = mostRecent.entryId {
                line += " citing \(entryId)"
            }
            if let reason = mostRecent.reason {
                line += " (\(reason.rawValue))"
            }
            lines.append(line)
        }

        for kind in ProvocationKind.allCases {
            guard let aggregate = byKind[kind], !aggregate.isEmpty else { continue }
            var line = "\(kind.rawValue): \(aggregate.upCount) up / \(aggregate.downCount) down | weighted \(Self.format(aggregate.weightedUp)) up / \(Self.format(aggregate.weightedDown)) down"
            if aggregate.downBias >= 1.5 {
                line += " | currently suppressed"
            }
            lines.append(line)
        }

        if !downvotedEntryIds.isEmpty {
            lines.append("entries recently thumbs-downed: \(downvotedEntryIds.joined(separator: ", "))")
        }

        if !stronglySuppressedEntryIds.isEmpty {
            lines.append("strongly suppressed entries right now: \(stronglySuppressedEntryIds.joined(separator: ", "))")
        }

        if !negativeReasonWeights.isEmpty {
            let formattedReasons = negativeReasonWeights
                .sorted { lhs, rhs in
                    if lhs.value == rhs.value {
                        return lhs.key.rawValue < rhs.key.rawValue
                    }
                    return lhs.value > rhs.value
                }
                .map { "\($0.key.rawValue) \(Self.format($0.value))" }
                .joined(separator: ", ")
            lines.append("active negative reasons: \(formattedReasons)")
        }

        let guardrails = activeGuardrails
        if !guardrails.isEmpty {
            lines.append("active guardrails:")
            lines.append(contentsOf: guardrails.map { "- \($0)" })
        }

        if !recentNegativeNotes.isEmpty {
            lines.append("recent feedback notes:")
            lines.append(contentsOf: recentNegativeNotes.map { sample in
                if let reason = sample.reason {
                    return "- \(reason.rawValue): \"\(sample.note)\""
                }
                return "- free_text: \"\(sample.note)\""
            })
        }

        return lines.joined(separator: "\n")
    }

    private var activeGuardrails: [String] {
        negativeReasonWeights
            .filter { $0.value >= 0.8 }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key.rawValue < rhs.key.rawValue
                }
                return lhs.value > rhs.value
            }
            .map { $0.key.promptGuidance }
    }

    private static func normalizeNote(_ note: String?) -> String? {
        guard let note else { return nil }
        let collapsed = note
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= 140 {
            return collapsed
        }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: 140)
        return String(collapsed[..<cutoff]) + "..."
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
