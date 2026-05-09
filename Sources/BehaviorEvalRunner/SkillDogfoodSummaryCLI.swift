import Foundation

enum CLISkillDogfoodSummary {
    struct Options {
        var input = "~/Library/Application Support/Nous/skill-fold-dogfood.jsonl"
        var days = 30
        var now = Date()
    }

    struct SkillReference: Decodable {
        let id: String
        let name: String
        let priority: Int

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case priority
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = try container.decode(String.self, forKey: .id)
            let name = try container.decode(String.self, forKey: .name)
            let priority = try container.decode(Int.self, forKey: .priority)
            self.id = id
            self.name = Self.safeLogName(id: id, rawName: name)
            self.priority = priority
        }

        private static func safeLogName(id: String, rawName: String) -> String {
            let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let allowedScalars = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
            )
            let isSafeName = !trimmedName.isEmpty
                && trimmedName.unicodeScalars.count <= 80
                && trimmedName.unicodeScalars.allSatisfy { allowedScalars.contains($0) }

            if isSafeName {
                return trimmedName
            }

            let safeIDPrefix = id.lowercased()
                .unicodeScalars
                .filter { allowedScalars.contains($0) }
                .prefix(8)
            let suffix = String(String.UnicodeScalarView(safeIDPrefix))
            return "skill-\(suffix.isEmpty ? "unknown" : suffix)"
        }
    }

    struct TurnEvent: Decodable {
        let recordedAt: Date
        let matchedSkills: [SkillReference]
        let loadedSkills: [SkillReference]
        let inlineSkills: [SkillReference]
    }

    struct TopSkill {
        let id: String
        let name: String
        let count: Int
    }
}

func runDogfoodSummaryCommand(_ arguments: [String]) throws -> String {
    let options = try parseDogfoodSummaryOptions(arguments)
    let inputURL = URL(fileURLWithPath: expandedPath(options.input))
    let events = try loadDogfoodEvents(from: inputURL)
    let summary = summarizeDogfood(events: events, days: options.days, now: options.now)

    var lines = [
        "skill dogfood summary (\(options.days) days)",
        "input: \(inputURL.path)",
        "turns: \(summary.turnCount)",
        "active days: \(summary.activeDayCount)",
        "zero-signal days: \(summary.zeroSignalDayCount)"
    ]

    if summary.topSkills.isEmpty {
        lines.append("top skills: none")
    } else {
        lines.append("top skills:")
        lines.append(
            contentsOf: summary.topSkills.map { "- \($0.name): \($0.count)" }
        )
    }

    return lines.joined(separator: "\n")
}

func parseDogfoodSummaryOptions(_ arguments: [String]) throws -> CLISkillDogfoodSummary.Options {
    var options = CLISkillDogfoodSummary.Options()
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
            print("usage: BehaviorEvalRunner dogfood-summary [--input path] [--days 30]")
            exit(0)
        default:
            throw CLIError.invalidArgument(argument)
        }
        index += 1
    }
    return options
}

func loadDogfoodEvents(from url: URL) throws -> [CLISkillDogfoodSummary.TurnEvent] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let contents = try String(contentsOf: url, encoding: .utf8)
    return contents.split(separator: "\n").compactMap { line in
        try? decoder.decode(
            CLISkillDogfoodSummary.TurnEvent.self,
            from: Data(String(line).utf8)
        )
    }
}

func summarizeDogfood(
    events: [CLISkillDogfoodSummary.TurnEvent],
    days: Int,
    now: Date
) -> (
    turnCount: Int,
    activeDayCount: Int,
    zeroSignalDayCount: Int,
    topSkills: [CLISkillDogfoodSummary.TopSkill]
) {
    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
    let recent = events.filter { $0.recordedAt >= cutoff && $0.recordedAt <= now }
    let activeDayKeys = Set(recent.map { dayKey(for: $0.recordedAt) })
    let topSkills = dogfoodSkillCounts(in: recent).values.sorted {
        if $0.count != $1.count { return $0.count > $1.count }
        return $0.name < $1.name
    }

    return (
        turnCount: recent.count,
        activeDayCount: activeDayKeys.count,
        zeroSignalDayCount: max(0, days - activeDayKeys.count),
        topSkills: topSkills
    )
}

func dogfoodSkillCounts(
    in events: [CLISkillDogfoodSummary.TurnEvent]
) -> [String: CLISkillDogfoodSummary.TopSkill] {
    var counts: [String: (name: String, count: Int)] = [:]
    for event in events {
        var seen: Set<String> = []
        for skill in event.matchedSkills + event.loadedSkills + event.inlineSkills {
            guard !seen.contains(skill.id) else { continue }
            seen.insert(skill.id)
            let current = counts[skill.id]
            counts[skill.id] = (
                name: skill.name,
                count: (current?.count ?? 0) + 1
            )
        }
    }

    return counts.reduce(into: [:]) { output, pair in
        output[pair.key] = CLISkillDogfoodSummary.TopSkill(
            id: pair.key,
            name: pair.value.name,
            count: pair.value.count
        )
    }
}

func dayKey(for date: Date) -> Int {
    Int(floor(date.timeIntervalSince1970 / 86_400))
}

func expandedPath(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" { return home }
    return home + String(path.dropFirst())
}
