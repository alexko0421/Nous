// Sources/ProvocationFixtureRunner/main.swift
// NOTE: No `import Nous` — source files are included directly in this target.
import Foundation

struct FixtureCase: Decodable {
    struct Pool: Decodable { let id: String; let text: String; let scope: String }
    struct Expected: Decodable {
        let shouldProvoke: Bool
        let userState: String?
        let entryId: String?
        enum CodingKeys: String, CodingKey {
            case shouldProvoke = "should_provoke"
            case userState = "user_state"
            case entryId = "entry_id"
        }
    }
    let name: String
    let userMessage: String
    let chatMode: String
    let citablePool: [Pool]
    let expected: Expected
    enum CodingKeys: String, CodingKey {
        case name
        case userMessage = "user_message"
        case chatMode = "chat_mode"
        case citablePool = "citable_pool"
        case expected
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: ProvocationFixtureRunner <fixtures-dir>\n", stderr)
    exit(64)
}
let fixturesDir = URL(fileURLWithPath: CommandLine.arguments[1])

guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
    fputs("ANTHROPIC_API_KEY required.\n", stderr); exit(64)
}
let llm = ClaudeLLMService(apiKey: apiKey, model: "claude-haiku-4-5-20251001")
let judge = ProvocationJudge(llmService: llm, timeout: 5.0)

let files = try FileManager.default.contentsOfDirectory(at: fixturesDir,
    includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

var failures = 0

for file in files {
    let data = try Data(contentsOf: file)
    let fx = try JSONDecoder().decode(FixtureCase.self, from: data)

    let unknownScope = fx.citablePool.first(where: { MemoryScope(rawValue: $0.scope) == nil })
    if let bad = unknownScope {
        failures += 1
        print("💥 \(fx.name) — unknown scope '\(bad.scope)' in citable_pool")
        continue
    }
    guard let mode = ChatMode(rawValue: fx.chatMode) else {
        failures += 1
        print("💥 \(fx.name) — unknown chat_mode '\(fx.chatMode)'")
        continue
    }
    let pool = fx.citablePool.map { CitableEntry(
        id: $0.id, text: $0.text,
        scope: MemoryScope(rawValue: $0.scope)!
    )}

    do {
        let verdict = try await judge.judge(
            userMessage: fx.userMessage,
            citablePool: pool,
            chatMode: mode,
            provider: .claude
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
