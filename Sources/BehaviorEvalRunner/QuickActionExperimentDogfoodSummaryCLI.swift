import Foundation

enum CLIHandoffABSummary {
    struct Options {
        var input = "~/Library/Application Support/Nous/quick-action-experiment-dogfood.jsonl"
        var days = 30
        var now = Date()
    }

    struct Event: Decodable {
        let recordedAt: Date
        let experimentId: String
        let mode: String
        let variant: String
    }

    struct ExperimentSummary {
        let experimentId: String
        let mode: String
        let controlCount: Int
        let candidateCount: Int
    }
}

func runHandoffABSummaryCommand(_ arguments: [String]) throws -> String {
    let options = try parseHandoffABSummaryOptions(arguments)
    let inputURL = URL(fileURLWithPath: expandedPath(options.input))
    let events = try loadHandoffABEvents(from: inputURL)
    let summary = summarizeHandoffAB(events: events, days: options.days, now: options.now)

    var lines = [
        "human-judgment handoff A/B summary (\(options.days) days)",
        "input: \(inputURL.path)",
        "turns: \(summary.turnCount)",
        "active days: \(summary.activeDayCount)",
        "zero-signal days: \(summary.zeroSignalDayCount)"
    ]

    if summary.experiments.isEmpty {
        lines.append("experiments: none")
    } else {
        lines.append("experiments:")
        lines.append(contentsOf: summary.experiments.map {
            "- \($0.experimentId) mode=\($0.mode) control=\($0.controlCount) candidate=\($0.candidateCount)"
        })
    }

    lines.append(contentsOf: [
        "manual scoring rubric:",
        "- Alex view preserved before AI framing?",
        "- AI reframed the problem silently?",
        "- One-sentence mental model is repeatable without the model?",
        "- Annoyance or learning-mode flavor increased?"
    ])

    return lines.joined(separator: "\n")
}

func parseHandoffABSummaryOptions(_ arguments: [String]) throws -> CLIHandoffABSummary.Options {
    var options = CLIHandoffABSummary.Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--input":
            options.input = try value(after: argument, in: arguments, index: &index)
        case "--days":
            let rawValue = try value(after: argument, in: arguments, index: &index)
            guard let days = Int(rawValue), days > 0 else {
                throw CLIError.invalidArgument("--days \(rawValue)")
            }
            options.days = days
        case "--help", "-h":
            print("usage: BehaviorEvalRunner handoff-ab-summary [--input path] [--days 30]")
            exit(0)
        default:
            throw CLIError.invalidArgument(argument)
        }
        index += 1
    }
    return options
}

func loadHandoffABEvents(from url: URL) throws -> [CLIHandoffABSummary.Event] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let contents = try String(contentsOf: url, encoding: .utf8)
    return contents.split(separator: "\n").compactMap { line in
        try? decoder.decode(
            CLIHandoffABSummary.Event.self,
            from: Data(String(line).utf8)
        )
    }
}

func summarizeHandoffAB(
    events: [CLIHandoffABSummary.Event],
    days: Int,
    now: Date
) -> (
    turnCount: Int,
    activeDayCount: Int,
    zeroSignalDayCount: Int,
    experiments: [CLIHandoffABSummary.ExperimentSummary]
) {
    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
    let recent = events.filter { $0.recordedAt >= cutoff && $0.recordedAt <= now }
    let activeDayKeys = Set(recent.map { dayKey(for: $0.recordedAt) })

    var buckets: [String: (mode: String, control: Int, candidate: Int)] = [:]
    for event in recent {
        let current = buckets[event.experimentId] ?? (event.mode, 0, 0)
        switch event.variant {
        case "control":
            buckets[event.experimentId] = (event.mode, current.control + 1, current.candidate)
        case "candidate":
            buckets[event.experimentId] = (event.mode, current.control, current.candidate + 1)
        default:
            buckets[event.experimentId] = current
        }
    }

    let experiments = buckets
        .map {
            CLIHandoffABSummary.ExperimentSummary(
                experimentId: $0.key,
                mode: $0.value.mode,
                controlCount: $0.value.control,
                candidateCount: $0.value.candidate
            )
        }
        .sorted { $0.experimentId < $1.experimentId }

    return (
        turnCount: recent.count,
        activeDayCount: activeDayKeys.count,
        zeroSignalDayCount: max(0, days - activeDayKeys.count),
        experiments: experiments
    )
}
