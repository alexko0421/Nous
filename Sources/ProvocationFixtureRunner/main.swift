// Sources/ProvocationFixtureRunner/main.swift
// NOTE: No `import Nous` — source files are included directly in this target.
import Foundation

struct FixtureCase: Decodable {
    struct Pool: Decodable { let id: String; let text: String; let scope: String }
    struct Expected: Decodable {
        let shouldProvoke: Bool
        let userState: String?
        let entryId: String?
        let inferredMode: String?
        enum CodingKeys: String, CodingKey {
            case shouldProvoke = "should_provoke"
            case userState = "user_state"
            case entryId = "entry_id"
            case inferredMode = "inferred_mode"
        }
    }
    let name: String
    let userMessage: String
    let previousMode: String?   // nil == first turn
    let citablePool: [Pool]
    let expected: Expected
    enum CodingKeys: String, CodingKey {
        case name
        case userMessage = "user_message"
        case previousMode = "previous_mode"
        case citablePool = "citable_pool"
        case expected
    }

    func validated(fileStem: String) -> FixtureValidationResult {
        guard name == fileStem else {
            return .invalid("\(fileStem): name must match file stem")
        }
        guard !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid("\(name): user_message is empty")
        }
        if let raw = previousMode, ChatMode(rawValue: raw) == nil {
            return .invalid("\(name): unknown previous_mode '\(raw)'")
        }
        var evidenceIds = Set<String>()
        for entry in citablePool {
            guard !entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .invalid("\(name): citable_pool contains empty id")
            }
            guard evidenceIds.insert(entry.id).inserted else {
                return .invalid("\(name): duplicate citable_pool id '\(entry.id)'")
            }
            guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .invalid("\(name): citable_pool entry \(entry.id) has empty text")
            }
            guard MemoryScope(rawValue: entry.scope) != nil else {
                return .invalid("\(name): unknown scope '\(entry.scope)' in citable_pool")
            }
        }
        if let raw = expected.userState, UserState(rawValue: raw) == nil {
            return .invalid("\(name): unknown expected.user_state '\(raw)'")
        }
        if let raw = expected.inferredMode, ChatMode(rawValue: raw) == nil {
            return .invalid("\(name): unknown expected.inferred_mode '\(raw)'")
        }
        if let entryId = expected.entryId,
           !evidenceIds.contains(entryId) {
            return .invalid("\(name): expected.entry_id '\(entryId)' is not in citable_pool")
        }
        return .valid
    }
}

enum FixtureValidationResult: Equatable {
    case valid
    case invalid(String)
}

struct RunnerOptions {
    let fixturesDirectory: URL
    let dryRun: Bool

    static func parse(arguments: [String]) -> RunnerOptions? {
        guard arguments.count >= 2 else { return nil }
        var dryRun = false
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--dry-run":
                dryRun = true
                index += 1
            default:
                return nil
            }
        }
        return RunnerOptions(
            fixturesDirectory: URL(fileURLWithPath: arguments[1]),
            dryRun: dryRun
        )
    }
}

guard let options = RunnerOptions.parse(arguments: CommandLine.arguments) else {
    fputs("usage: ProvocationFixtureRunner <fixtures-dir> [--dry-run]\n", stderr)
    exit(64)
}

let files = try FileManager.default.contentsOfDirectory(at: options.fixturesDirectory,
    includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !files.isEmpty else {
    fputs("No provocation fixtures found in \(options.fixturesDirectory.path)\n", stderr)
    exit(1)
}

var failures = 0

var fixtures: [(URL, FixtureCase)] = []
for file in files {
    let data = try Data(contentsOf: file)
    let fx = try JSONDecoder().decode(FixtureCase.self, from: data)
    switch fx.validated(fileStem: file.deletingPathExtension().lastPathComponent) {
    case .valid:
        fixtures.append((file, fx))
    case .invalid(let message):
        failures += 1
        print("💥 \(message)")
    }
}

if options.dryRun {
    if failures == 0 {
        print("Validated \(fixtures.count) provocation fixtures.")
    }
    exit(failures == 0 ? 0 : 1)
}

guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
    fputs("ANTHROPIC_API_KEY required. Use --dry-run for no-LLM fixture validation.\n", stderr)
    exit(64)
}
let llm = ClaudeLLMService(apiKey: apiKey, model: "claude-sonnet-4-6")
let judge = ProvocationJudge(llmService: llm, timeout: 5.0)

for (_, fx) in fixtures {
    let previousMode: ChatMode?
    if let raw = fx.previousMode {
        previousMode = ChatMode(rawValue: raw)
    } else {
        previousMode = nil
    }
    let pool = fx.citablePool.map { CitableEntry(
        id: $0.id, text: $0.text,
        scope: MemoryScope(rawValue: $0.scope)!
    )}

    do {
        let verdict = try await judge.judge(
            userMessage: fx.userMessage,
            citablePool: pool,
            previousMode: previousMode,
            provider: .claude,
            feedbackLoop: nil
        )
        var diffs: [String] = []
        if verdict.shouldProvoke != fx.expected.shouldProvoke {
            diffs.append("should_provoke: got=\(verdict.shouldProvoke) want=\(fx.expected.shouldProvoke)")
        }
        if let wantState = fx.expected.userState, verdict.userState.rawValue != wantState {
            diffs.append("user_state: got=\(verdict.userState.rawValue) want=\(wantState)")
        }
        if let wantEntry = fx.expected.entryId, verdict.entryId != wantEntry {
            diffs.append("entry_id: got=\(verdict.entryId ?? "nil") want=\(wantEntry)")
        }
        if let wantMode = fx.expected.inferredMode, verdict.inferredMode.rawValue != wantMode {
            diffs.append("inferred_mode: got=\(verdict.inferredMode.rawValue) want=\(wantMode)")
        }
        if diffs.isEmpty {
            print("✅ \(fx.name)")
        } else {
            failures += 1
            print("❌ \(fx.name)")
            diffs.forEach { print("   \($0)") }
            print("   reason: \(verdict.reason)")
        }
    } catch {
        failures += 1
        print("💥 \(fx.name) — judge threw \(error)")
    }
}

print("")
print("\(files.count - failures)/\(files.count) passed")
exit(failures == 0 ? 0 : 1)
