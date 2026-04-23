// Sources/ReflectionFixtureRunner/main.swift
// Exports one week of ChatMessage rows from a Nous SQLite DB into a JSON
// fixture for the WeeklyReflectionService prompt feasibility spike.
//
// Usage:
//   ReflectionFixtureRunner --db <path> --project <uuid> --week YYYY-WXX --out <dir>
//
// Example:
//   ReflectionFixtureRunner \
//     --db ~/Library/Containers/com.nous.app.Nous/Data/Library/Application\ Support/Nous/nous.sqlite \
//     --project 7B3F...A2 \
//     --week 2026-W17 \
//     --out ~/.gstack/projects/alexko0421-Nous/fixtures
//
// No `import Nous` — Database.swift is included directly in this target.
import Foundation

// MARK: - Args

struct Args {
    var dbPath: String
    var projectId: String
    var week: String  // ISO week: YYYY-WXX
    var outDir: String
}

func parseArgs() -> Args {
    var db: String?
    var project: String?
    var week: String?
    var out: String?
    var i = 1
    let argv = CommandLine.arguments
    while i < argv.count {
        let k = argv[i]
        let v = (i + 1 < argv.count) ? argv[i + 1] : nil
        switch k {
        case "--db":      db = v; i += 2
        case "--project": project = v; i += 2
        case "--week":    week = v; i += 2
        case "--out":     out = v; i += 2
        default:
            fputs("unknown arg: \(k)\n", stderr); exit(64)
        }
    }
    guard let db, let project, let week, let out else {
        fputs("usage: ReflectionFixtureRunner --db <path> --project <uuid> --week YYYY-WXX --out <dir>\n", stderr)
        exit(64)
    }
    return Args(dbPath: db, projectId: project, week: week, outDir: out)
}

// MARK: - ISO week parsing

/// Returns (start, end) for an ISO-8601 week string like "2026-W17".
/// Week starts Monday 00:00 local, ends the following Monday 00:00 local.
func weekRange(_ isoWeek: String) -> (start: Date, end: Date)? {
    let parts = isoWeek.split(separator: "-")
    guard parts.count == 2,
          let year = Int(parts[0]),
          parts[1].hasPrefix("W"),
          let week = Int(parts[1].dropFirst())
    else { return nil }

    var cal = Calendar(identifier: .iso8601)
    cal.timeZone = TimeZone.current
    var comps = DateComponents()
    comps.weekOfYear = week
    comps.yearForWeekOfYear = year
    comps.weekday = cal.firstWeekday  // Monday for ISO
    guard let start = cal.date(from: comps),
          let end = cal.date(byAdding: .day, value: 7, to: start)
    else { return nil }
    return (start, end)
}

// MARK: - Conversation / message models for export

struct ExportMessage: Encodable {
    let id: String
    let role: String
    let content: String
    let timestamp: String  // ISO-8601
}

struct ExportConversation: Encodable {
    let node_id: String
    let node_title: String
    let messages: [ExportMessage]
}

struct ExportFixture: Encodable {
    let project_id: String
    let week_start: String
    let week_end: String
    let message_count: Int
    let conversation_count: Int
    let conversations: [ExportConversation]
}

// MARK: - Main

let args = parseArgs()

guard let range = weekRange(args.week) else {
    fputs("could not parse --week '\(args.week)' (expected YYYY-WXX)\n", stderr); exit(64)
}

let db: Database
do {
    db = try Database(path: (args.dbPath as NSString).expandingTildeInPath)
} catch {
    fputs("failed to open db: \(error)\n", stderr); exit(1)
}

let isoFmt = ISO8601DateFormatter()
isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let isoOut = ISO8601DateFormatter()
isoOut.formatOptions = [.withFullDate]

// Pull messages for nodes in this project during the week window.
// `messages.timestamp` is stored as REAL unix seconds.
let sql = """
    SELECT m.id, m.nodeId, n.title, m.role, m.content, m.timestamp
    FROM messages m
    JOIN nodes n ON n.id = m.nodeId
    WHERE n.projectId = ?
      AND m.timestamp >= ?
      AND m.timestamp <  ?
    ORDER BY m.nodeId, m.timestamp ASC;
"""

let stmt: Statement
do {
    stmt = try db.prepare(sql)
    try stmt.bind(args.projectId, at: 1)
    try stmt.bind(range.start.timeIntervalSince1970, at: 2)
    try stmt.bind(range.end.timeIntervalSince1970, at: 3)
} catch {
    fputs("query prepare failed: \(error)\n", stderr); exit(1)
}

var grouped: [String: (title: String, messages: [ExportMessage])] = [:]
var messageCount = 0

do {
    while try stmt.step() {
        let messageId = stmt.text(at: 0) ?? ""
        let nodeId    = stmt.text(at: 1) ?? ""
        let title     = stmt.text(at: 2) ?? ""
        let role      = stmt.text(at: 3) ?? ""
        let content   = stmt.text(at: 4) ?? ""
        let ts        = stmt.double(at: 5)
        let iso       = isoFmt.string(from: Date(timeIntervalSince1970: ts))

        let msg = ExportMessage(id: messageId, role: role, content: content, timestamp: iso)
        if var existing = grouped[nodeId] {
            existing.messages.append(msg)
            grouped[nodeId] = existing
        } else {
            grouped[nodeId] = (title, [msg])
        }
        messageCount += 1
    }
} catch {
    fputs("query step failed: \(error)\n", stderr); exit(1)
}

let conversations = grouped.map { (nodeId, pair) in
    ExportConversation(node_id: nodeId, node_title: pair.title, messages: pair.messages)
}.sorted { $0.node_id < $1.node_id }

let fixture = ExportFixture(
    project_id: args.projectId,
    week_start: isoOut.string(from: range.start),
    week_end:   isoOut.string(from: range.end),
    message_count: messageCount,
    conversation_count: conversations.count,
    conversations: conversations
)

let outDir = (args.outDir as NSString).expandingTildeInPath
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let outPath = "\(outDir)/reflection-fixture-\(args.week).json"

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let data = try encoder.encode(fixture)
try data.write(to: URL(fileURLWithPath: outPath))

print("wrote \(outPath)")
print("  project \(args.projectId)")
print("  week    \(args.week) → \(isoOut.string(from: range.start)) … \(isoOut.string(from: range.end))")
print("  \(conversations.count) conversations, \(messageCount) messages")
