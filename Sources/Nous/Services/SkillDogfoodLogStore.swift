import Foundation

protocol SkillDogfoodLogging {
    func record(_ event: SkillDogfoodTurnEvent) throws
}

final class SkillDogfoodLogStore: SkillDogfoodLogging {
    private let url: URL
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    static func defaultStore(fileManager: FileManager = .default) throws -> SkillDogfoodLogStore {
        let root = try defaultDirectory(fileManager: fileManager)
        return SkillDogfoodLogStore(
            url: root.appendingPathComponent("skill-fold-dogfood.jsonl")
        )
    }

    static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return support.appendingPathComponent("Nous", isDirectory: true)
    }

    func record(_ event: SkillDogfoodTurnEvent) throws {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let line = try SkillDogfoodJSONL.encode(event) + "\n"
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    func loadEvents() throws -> [SkillDogfoodTurnEvent] {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(separator: "\n").compactMap { line in
            try? JSONDecoder.skillDogfood.decode(
                SkillDogfoodTurnEvent.self,
                from: Data(String(line).utf8)
            )
        }.sorted { $0.recordedAt < $1.recordedAt }
    }

    func summary(days: Int, now: Date = Date()) throws -> SkillDogfoodSummary {
        let windowDays = max(1, days)
        let since = now.addingTimeInterval(-Double(windowDays) * 86_400)
        let events = try loadEvents()
            .filter { $0.recordedAt >= since && $0.recordedAt <= now }

        var activeDays = Set<Int>()
        var skillCounts: [String: Int] = [:]
        for event in events {
            activeDays.insert(Int(floor(event.recordedAt.timeIntervalSince1970 / 86_400)))
            var seenSkillIds: Set<UUID> = []
            for skill in event.matchedSkills + event.loadedSkills + event.inlineSkills {
                guard !seenSkillIds.contains(skill.id) else { continue }
                seenSkillIds.insert(skill.id)
                skillCounts[skill.name, default: 0] += 1
            }
        }

        let topSkills = skillCounts
            .map { SkillDogfoodTopSkill(name: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.name < $1.name
            }
            .prefix(5)
            .map { $0 }

        return SkillDogfoodSummary(
            turnCount: events.count,
            activeDayCount: activeDays.count,
            zeroSignalDayCount: max(0, windowDays - activeDays.count),
            topSkills: topSkills
        )
    }
}

private enum SkillDogfoodJSONL {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder.skillDogfood.encode(value)
        guard let line = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Skill dogfood JSON was not valid UTF-8."
                )
            )
        }
        return line.replacingOccurrences(of: "\n", with: "")
    }
}

private extension JSONEncoder {
    static var skillDogfood: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var skillDogfood: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
